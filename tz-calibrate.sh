#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}请以 root 权限运行此脚本${NC}"; exit 1; }

# 检测包管理器
if command -v apt-get &>/dev/null; then
    PKG="apt-get"
    UPDATE="apt-get update -y"
elif command -v yum &>/dev/null; then
    PKG="yum"
    UPDATE="yum makecache -y"
elif command -v dnf &>/dev/null; then
    PKG="dnf"
    UPDATE="dnf makecache -y"
elif command -v pacman &>/dev/null; then
    PKG="pacman"
    UPDATE="pacman -Sy"
else
    echo -e "${RED}未检测到支持的包管理器${NC}"; exit 1
fi

install_pkg() {
    local pkg_name="$1"
    echo -e "${YELLOW}正在安装 ${pkg_name}...${NC}"
    $UPDATE &>/dev/null
    if [[ "$PKG" == "pacman" ]]; then
        pacman -S --noconfirm "$pkg_name"
    else
        $PKG install -y "$pkg_name"
    fi
}

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}      VPS 时区 & 时间 自动校准脚本        ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# ============================================================
# 第一步：根据公网IP自动设置时区
# ============================================================
echo -e "${GREEN}[1/3] 正在根据公网IP检测时区...${NC}"

TIMEZONE=""
IP_INFO_URLS=(
    "http://ip-api.com/json"
    "https://ipapi.co/json"
    "https://ipinfo.io/json"
)

for url in "${IP_INFO_URLS[@]}"; do
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)
    if [[ -n "$RESPONSE" ]]; then
        TZ=$(echo "$RESPONSE" | grep -oP '"timezone"\s*:\s*"\K[^"]+' 2>/dev/null)
        [[ -z "$TZ" ]] && TZ=$(echo "$RESPONSE" | grep -oP '"time_zone"\s*:\s*"\K[^"]+' 2>/dev/null)
        if [[ -n "$TZ" && -f "/usr/share/zoneinfo/$TZ" ]]; then
            TIMEZONE="$TZ"
            IP=$(echo "$RESPONSE" | grep -oP '"(ip|query)"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
            echo -e "  公网IP: ${YELLOW}${IP:-未知}${NC}"
            echo -e "  数据源: ${YELLOW}${url}${NC}"
            break
        fi
    fi
done

if [[ -z "$TIMEZONE" ]]; then
    echo -e "${RED}  无法自动检测时区，默认使用 Asia/Shanghai${NC}"
    TIMEZONE="Asia/Shanghai"
fi

CURRENT_TZ=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}')
echo -e "  当前时区: ${YELLOW}${CURRENT_TZ:-未知}${NC}"
echo -e "  检测时区: ${GREEN}${TIMEZONE}${NC}"

if [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
    echo -e "  ${GREEN}时区已正确，无需修改${NC}"
else
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "  ${GREEN}✔ 时区已设置为: ${TIMEZONE}${NC}"
    else
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" > /etc/timezone 2>/dev/null
        echo -e "  ${GREEN}✔ 时区已设置为: ${TIMEZONE}${NC}"
    fi
fi

echo ""

# ============================================================
# 第二步：从网站 HTTP Date 头获取网络时间并写入
# ============================================================
echo -e "${GREEN}[2/3] 正在从多个网站获取网络时间...${NC}"

declare -A SITES=(
    ["Apple"]="https://www.apple.com"
    ["Cloudflare"]="https://www.cloudflare.com"
    ["Google"]="https://www.google.com"
    ["Microsoft"]="https://www.microsoft.com"
    ["Amazon"]="https://www.amazon.com"
)

TIMESTAMPS=()
echo ""

for name in "${!SITES[@]}"; do
    DATE_STR=$(curl -sI --connect-timeout 5 --max-time 10 "${SITES[$name]}" 2>/dev/null | grep -i "^date:" | sed 's/[Dd]ate: //;s/\r//')
    if [[ -n "$DATE_STR" ]]; then
        EPOCH=$(date -d "$DATE_STR" +%s 2>/dev/null)
        if [[ -n "$EPOCH" && "$EPOCH" -gt 0 ]]; then
            TIMESTAMPS+=("$EPOCH")
            echo -e "  ${GREEN}✔${NC} ${name}: ${DATE_STR}"
        else
            echo -e "  ${RED}✘${NC} ${name}: 解析失败"
        fi
    else
        echo -e "  ${RED}✘${NC} ${name}: 无法连接"
    fi
done

echo ""

if [[ ${#TIMESTAMPS[@]} -eq 0 ]]; then
    echo -e "${RED}  未能从任何网站获取时间，跳过HTTP时间同步${NC}"
else
    # 取中位数防止异常值
    IFS=$'\n' SORTED=($(sort -n <<<"${TIMESTAMPS[*]}")); unset IFS
    MID=$(( ${#SORTED[@]} / 2 ))
    MEDIAN_EPOCH="${SORTED[$MID]}"
    NETWORK_TIME=$(date -d "@$MEDIAN_EPOCH" "+%Y-%m-%d %H:%M:%S %Z")
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S %Z")

    echo -e "  当前系统时间: ${YELLOW}${CURRENT_TIME}${NC}"
    echo -e "  网络参考时间: ${GREEN}${NETWORK_TIME}${NC}"

    LOCAL_EPOCH=$(date +%s)
    DIFF=$(( MEDIAN_EPOCH - LOCAL_EPOCH ))
    ABS_DIFF=${DIFF#-}

    if [[ $ABS_DIFF -le 2 ]]; then
        echo -e "  ${GREEN}系统时间与网络时间偏差 ≤2秒，无需校准${NC}"
    else
        echo -e "  ${YELLOW}偏差 ${ABS_DIFF} 秒，正在写入网络时间...${NC}"
        timedatectl set-ntp false 2>/dev/null
        date -s "@$MEDIAN_EPOCH" &>/dev/null
        if [[ $? -eq 0 ]]; then
            hwclock --systohc 2>/dev/null
            echo -e "  ${GREEN}✔ 系统时间已校准为: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        else
            echo -e "  ${RED}✘ 时间写入失败（可能受限于容器环境）${NC}"
        fi
    fi
fi

echo ""

# ============================================================
# 第三步：选择NTP校准工具保持长期同步
# ============================================================
echo -e "${GREEN}[3/3] 配置 NTP 时间同步工具（保持长期自动校准）${NC}"
echo ""

# ——————————————————————————————————————
# 公共NTP源
# ——————————————————————————————————————
NTP_SERVERS=(
    "time.cloudflare.com"
    "time.apple.com"
    "time.google.com"
    "ntp.aliyun.com"
    "ntp.tencent.com"
    "pool.ntp.org"
)

# ——————————————————————————————————————
# chrony 配置函数
# ——————————————————————————————————————
setup_chrony() {
    systemctl stop systemd-timesyncd 2>/dev/null
    systemctl disable systemd-timesyncd 2>/dev/null
    systemctl stop ntpd 2>/dev/null
    systemctl disable ntpd 2>/dev/null

    if ! command -v chronyd &>/dev/null; then
        install_pkg chrony
    fi

    CHRONY_CONF=""
    for f in /etc/chrony/chrony.conf /etc/chrony.conf; do
        [[ -f "$f" ]] && CHRONY_CONF="$f" && break
    done
    [[ -z "$CHRONY_CONF" ]] && CHRONY_CONF="/etc/chrony.conf" && touch "$CHRONY_CONF"

    cp "$CHRONY_CONF" "${CHRONY_CONF}.bak.$(date +%s)"

    cat > "$CHRONY_CONF" <<EOF
# Chrony NTP 配置 - 自动生成 $(date '+%Y-%m-%d %H:%M:%S')
server time.cloudflare.com iburst
server time.apple.com iburst
server time.google.com iburst
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
pool pool.ntp.org iburst
makestep 1 3
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
rtcsync
EOF

    systemctl enable chronyd 2>/dev/null || systemctl enable chrony 2>/dev/null
    systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null
    sleep 2

    echo -e "${GREEN}✔ chrony 已配置并启动${NC}"
    echo ""
    echo -e "${CYAN}同步状态：${NC}"
    chronyc tracking 2>/dev/null
    echo ""
    chronyc sources -v 2>/dev/null
}

# ——————————————————————————————————————
# ntpdate 配置函数
# ——————————————————————————————————————
setup_ntpdate() {
    if ! command -v ntpdate &>/dev/null; then
        install_pkg ntpdate
    fi

    systemctl stop chronyd 2>/dev/null
    systemctl stop systemd-timesyncd 2>/dev/null
    timedatectl set-ntp false 2>/dev/null

    echo -e "${YELLOW}正在使用 ntpdate 同步时间...${NC}"
    SYNCED=0
    for srv in "${NTP_SERVERS[@]}"; do
        echo -e "  尝试: ${srv}"
        if ntpdate -u "$srv" 2>/dev/null; then
            echo -e "  ${GREEN}✔ 通过 ${srv} 同步成功${NC}"
            SYNCED=1
            break
        fi
    done

    if [[ $SYNCED -eq 0 ]]; then
        echo -e "  ${RED}✘ 所有NTP服务器均失败${NC}"
    else
        hwclock --systohc 2>/dev/null
        echo -e "  ${GREEN}✔ 已同步到硬件时钟${NC}"
    fi

    CRON_CMD="0 */6 * * * /usr/sbin/ntpdate -u time.cloudflare.com > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "ntpdate"; echo "$CRON_CMD") | crontab -
    echo ""
    echo -e "${GREEN}✔ 已添加 crontab 定时任务（每6小时同步一次）${NC}"
    echo -e "  ${CYAN}${CRON_CMD}${NC}"
}

# ——————————————————————————————————————
# timesyncd 配置函数
# ——————————————————————————————————————
setup_timesyncd() {
    systemctl stop chronyd 2>/dev/null
    systemctl disable chronyd 2>/dev/null

    if ! systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd"; then
        install_pkg systemd-timesyncd
    fi

    TIMESYNCD_CONF="/etc/systemd/timesyncd.conf"
    cp "$TIMESYNCD_CONF" "${TIMESYNCD_CONF}.bak.$(date +%s)" 2>/dev/null

    cat > "$TIMESYNCD_CONF" <<EOF
# systemd-timesyncd 配置 - 自动生成 $(date '+%Y-%m-%d %H:%M:%S')
[Time]
NTP=time.cloudflare.com time.apple.com time.google.com ntp.aliyun.com
FallbackNTP=ntp.tencent.com pool.ntp.org
EOF

    timedatectl set-ntp true 2>/dev/null
    systemctl enable systemd-timesyncd 2>/dev/null
    systemctl restart systemd-timesyncd 2>/dev/null
    sleep 2

    echo -e "${GREEN}✔ systemd-timesyncd 已配置并启动${NC}"
    echo ""
    echo -e "${CYAN}同步状态：${NC}"
    timedatectl timesync-status 2>/dev/null || timedatectl status 2>/dev/null
}

# ——————————————————————————————————————
# 核心判断：chrony 已安装则直接使用，否则让用户选择
# ——————————————————————————————————————
if command -v chronyd &>/dev/null; then
    echo -e "  ${GREEN}✔ 检测到 chrony 已安装，直接使用 chrony 进行时间同步（跳过选择）${NC}"
    echo ""
    setup_chrony
else
    # 检测其余工具安装状态
    NTPDATE_INSTALLED=0
    TIMESYNCD_INSTALLED=0
    command -v ntpdate &>/dev/null && NTPDATE_INSTALLED=1
    systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd" && TIMESYNCD_INSTALLED=1

    if [[ $NTPDATE_INSTALLED -eq 1 ]]; then
        NTPDATE_TAG="${GREEN}已安装${NC}"
    else
        NTPDATE_TAG="${RED}未安装${NC}"
    fi
    if [[ $TIMESYNCD_INSTALLED -eq 1 ]]; then
        TIMESYNCD_TAG="${GREEN}已安装${NC}"
    else
        TIMESYNCD_TAG="${RED}未安装${NC}"
    fi

    echo -e "  chrony:            ${RED}未安装${NC}"
    echo -e "  ntpdate:           $NTPDATE_TAG"
    echo -e "  systemd-timesyncd: $TIMESYNCD_TAG"
    echo ""
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  序号  │  工具名称           │  说明                              │${NC}"
    echo -e "${CYAN}├────────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  [1]   │  chrony (chronyd)   │  ${YELLOW}推荐${NC} 现代NTP，快速收敛，精度高     ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  [2]   │  ntpdate            │  传统一次性同步，需配合crontab      ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  [3]   │  systemd-timesyncd  │  systemd内置轻量SNTP客户端          ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  [0]   │  跳过               │  不配置NTP                         ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}三者区别说明：${NC}"
    echo -e "  ${GREEN}chrony${NC}:    现代NTP实现，启动后快速收敛，支持间歇性网络连接，适合"
    echo -e "             虚拟机/VPS/容器。能在大偏移下快速纠正，精度高，持续后台"
    echo -e "             运行自动保持同步。${YELLOW}【首选推荐】${NC}"
    echo ""
    echo -e "  ${GREEN}ntpdate${NC}:   传统一次性时间同步命令，执行一次校准一次，不驻留后台。"
    echo -e "             需配合 crontab 定时任务才能持续校准。许多新发行版已弃用。"
    echo -e "             适合临时快速校准或极简环境。"
    echo ""
    echo -e "  ${GREEN}systemd-timesyncd${NC}: systemd 自带轻量级 SNTP 客户端，开箱即用。"
    echo -e "             功能较简单，仅作为客户端同步，不能作为NTP服务器。"
    echo -e "             适合对精度要求不高、希望零配置的场景。"
    echo ""

    read -rp "请选择 [0-3] (默认1): " CHOICE
    CHOICE=${CHOICE:-1}

    case "$CHOICE" in
    1)
        echo ""
        setup_chrony
        ;;
    2)
        echo ""
        setup_ntpdate
        ;;
    3)
        echo ""
        setup_timesyncd
        ;;
    0)
        echo -e "${YELLOW}已跳过NTP工具配置${NC}"
        ;;
    *)
        echo -e "${RED}无效选择，已跳过${NC}"
        ;;
    esac
fi

echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}              校准完成 - 最终状态            ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  时区: ${GREEN}$(timedatectl 2>/dev/null | grep 'Time zone' | awk '{print $3}' || cat /etc/timezone 2>/dev/null)${NC}"
echo -e "  时间: ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  Epoch: ${GREEN}$(date +%s)${NC}"
echo ""
timedatectl 2>/dev/null
echo ""
echo -e "${GREEN}Done.${NC}"
