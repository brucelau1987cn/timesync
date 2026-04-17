#!/bin/bash

# ============================================================
# VPS 时区与时间自动校准脚本 v1.1
# 功能：自动识别时区 → 选择校时工具 → 从网络大站获取时间并自动校准
# 支持：Debian/Ubuntu、CentOS/RHEL/Fedora、Alpine
# ============================================================

set -euo pipefail

# ==================== 颜色定义 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==================== 工具函数 ====================
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BLUE}========================================${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BLUE}========================================${NC}"; }
divider() { echo -e "${CYAN}────────────────────────────────────────${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请以 root 权限运行此脚本：sudo bash $0"
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache -y"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
    else
        error "未检测到支持的包管理器"
        exit 1
    fi
    info "包管理器: ${BOLD}${PKG_MGR}${NC}"
}

# NTP 服务器池
NTP_SERVERS=(
    "pool.ntp.org"
    "time.cloudflare.com"
    "time.google.com"
    "time.apple.com"
    "ntp.aliyun.com"
)

# ==================== 第一步：根据公网IP确定时区 ====================
detect_timezone_by_ip() {
    header "第一步：根据公网 IP 自动检测时区"

    local public_ip=""
    local timezone=""

    info "正在获取公网 IP 地址..."
    local ip_services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    for svc in "${ip_services[@]}"; do
        public_ip=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$public_ip" && "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            info "公网 IP: ${BOLD}${public_ip}${NC}  (来源: $svc)"
            break
        fi
        public_ip=""
    done

    if [[ -z "$public_ip" ]]; then
        warn "无法获取公网 IP，使用 UTC 作为默认时区"
        DETECTED_TZ="UTC"
        return
    fi

    info "正在查询时区..."
    local tz_services=(
        "http://ip-api.com/json/${public_ip}?fields=timezone,country,city,query"
        "https://ipapi.co/${public_ip}/json/"
        "https://ipwho.is/${public_ip}"
    )

    for svc in "${tz_services[@]}"; do
        local resp
        resp=$(curl -s --max-time 5 "$svc" 2>/dev/null)
        if [[ -n "$resp" ]]; then
            timezone=$(echo "$resp" | grep -oP '"timezone"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
            if [[ -n "$timezone" && "$timezone" == *"/"* ]]; then
                local country city
                country=$(echo "$resp" | grep -oP '"country"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
                city=$(echo "$resp" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
                info "国家: ${BOLD}${country:-未知}${NC}  城市: ${BOLD}${city:-未知}${NC}"
                break
            fi
            timezone=""
        fi
    done

    if [[ -z "$timezone" ]]; then
        warn "无法确定时区，使用 UTC"
        timezone="UTC"
    fi

    DETECTED_TZ="$timezone"

    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '未知')

    divider
    echo -e "  检测到的时区: ${GREEN}${BOLD}${DETECTED_TZ}${NC}"
    echo -e "  当前系统时区: ${YELLOW}${current_tz}${NC}"
    divider

    echo ""
    read -rp "$(echo -e "${CYAN}是否将系统时区设置为 ${BOLD}${DETECTED_TZ}${NC}${CYAN} ? [Y/n]: ${NC}")" confirm
    confirm="${confirm:-Y}"

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_timezone "$DETECTED_TZ"
    else
        read -rp "$(echo -e "${CYAN}请手动输入时区 (如 Asia/Shanghai): ${NC}")" manual_tz
        if [[ -f "/usr/share/zoneinfo/${manual_tz}" ]]; then
            apply_timezone "$manual_tz"
            DETECTED_TZ="$manual_tz"
        else
            error "无效时区: $manual_tz，保持当前不变"
        fi
    fi
}

apply_timezone() {
    local tz="$1"
    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$tz"
    else
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
        echo "$tz" > /etc/timezone
    fi
    info "时区已设置为: ${BOLD}${tz}${NC}"
}

# ==================== 第二步：选择校时工具 ====================
select_sync_tool() {
    header "第二步：选择时间同步工具"

    # 检测安装状态
    local chrony_installed=false
    local ntpdate_installed=false
    local timesyncd_installed=false

    { command -v chronyd &>/dev/null || command -v chronyc &>/dev/null; } && chrony_installed=true
    command -v ntpdate &>/dev/null && ntpdate_installed=true
    { [[ -f /lib/systemd/system/systemd-timesyncd.service ]] || systemctl list-unit-files systemd-timesyncd.service &>/dev/null 2>&1; } && timesyncd_installed=true

    local c_st y_st t_st
    $chrony_installed    && c_st="${GREEN}[已安装]${NC}" || c_st="${RED}[未安装]${NC}"
    $ntpdate_installed   && y_st="${GREEN}[已安装]${NC}" || y_st="${RED}[未安装]${NC}"
    $timesyncd_installed && t_st="${GREEN}[已安装]${NC}" || t_st="${RED}[未安装]${NC}"

    echo ""
    echo -e "${BOLD}┌─────┬────────────────────┬──────────┬────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│ 编号│ 工具               │ 状态     │ 说明                                           │${NC}"
    echo -e "${BOLD}├─────┼────────────────────┼──────────┼────────────────────────────────────────────────┤${NC}"
    echo -e "│  1  │ ${CYAN}chrony${NC}             │ $c_st  │ ${GREEN}★ 推荐${NC} 精度微秒级，守护进程持续同步         │"
    echo -e "│     │                    │          │ 虚拟机/容器优化，支持间歇性网络，可当服务端   │"
    echo -e "├─────┼────────────────────┼──────────┼────────────────────────────────────────────────┤${NC}"
    echo -e "│  2  │ ${CYAN}ntpdate${NC}            │ $y_st  │ ${YELLOW}⚠ 已弃用${NC} 单次跳变校时，执行完即退出         │"
    echo -e "│     │                    │          │ 无守护进程，适合临时手动校时                   │"
    echo -e "├─────┼────────────────────┼──────────┼────────────────────────────────────────────────┤${NC}"
    echo -e "│  3  │ ${CYAN}systemd-timesyncd${NC}  │ $t_st  │ ${BLUE}◆ 最轻量${NC} systemd 内置 SNTP 客户端           │"
    echo -e "│     │                    │          │ 零额外依赖，精度毫秒级，仅客户端               │"
    echo -e "${BOLD}└─────┴────────────────────┴──────────┴────────────────────────────────────────────────┘${NC}"

    echo ""
    echo -e "${BOLD}核心区别：${NC}"
    divider
    echo -e "  ${CYAN}chrony${NC}      精度最高(μs)  守护进程  可当服务端  虚拟机优化  ${GREEN}← 生产首选${NC}"
    echo -e "  ${CYAN}ntpdate${NC}     精度中(ms)    单次执行  跑完退出    简单粗暴    ${YELLOW}← 临时校时${NC}"
    echo -e "  ${CYAN}timesyncd${NC}   精度中(ms)    守护进程  仅客户端    资源最少    ${BLUE}← 轻量VPS${NC}"
    divider
    echo ""

    read -rp "$(echo -e "${CYAN}请选择 [1/2/3] (默认1): ${NC}")" choice
    choice="${choice:-1}"

    case "$choice" in
        1) setup_chrony "$chrony_installed" ;;
        2) setup_ntpdate "$ntpdate_installed" ;;
        3) setup_timesyncd "$timesyncd_installed" ;;
        *) error "无效选择"; exit 1 ;;
    esac
}

install_pkg() {
    local pkg="$1"
    info "正在安装 ${pkg}..."
    $PKG_UPDATE &>/dev/null || true
    $PKG_INSTALL "$pkg"
    info "${pkg} 安装完成"
}

stop_conflicting_services() {
    local keep="$1"
    local services=("chronyd" "chrony" "ntp" "ntpd" "systemd-timesyncd")
    for svc in "${services[@]}"; do
        if [[ "$svc" != "$keep" ]]; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done
}

# ---------- chrony ----------
setup_chrony() {
    local installed=$1
    info "选择了 chrony"

    if [[ "$installed" == "false" ]]; then
        case "$PKG_MGR" in
            apt)        install_pkg chrony ;;
            yum|dnf)    install_pkg chrony ;;
            apk)        install_pkg chrony ;;
            pacman)     install_pkg chrony ;;
        esac
    fi

    stop_conflicting_services "chronyd"

    local chrony_conf
    if [[ -f /etc/chrony/chrony.conf ]]; then
        chrony_conf="/etc/chrony/chrony.conf"
    elif [[ -f /etc/chrony.conf ]]; then
        chrony_conf="/etc/chrony.conf"
    else
        mkdir -p /etc/chrony
        chrony_conf="/etc/chrony/chrony.conf"
    fi

    [[ -f "$chrony_conf" ]] && cp "$chrony_conf" "${chrony_conf}.bak.$(date +%s)"

    cat > "$chrony_conf" <<EOF
# 自动生成于 $(date)
server pool.ntp.org        iburst
server time.cloudflare.com iburst
server time.google.com     iburst
server time.apple.com      iburst
server ntp.aliyun.com      iburst

makestep 1.0 3
driftfile /var/lib/chrony/drift
rtcsync
logdir /var/log/chrony
EOF

    systemctl enable chronyd 2>/dev/null || systemctl enable chrony 2>/dev/null
    systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null

    # 等 chrony 完成首次同步
    info "等待 chrony 同步..."
    local max_wait=15
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if chronyc waitsync 1 0.1 0 0 &>/dev/null 2>&1; then
            break
        fi
        sleep 1
        ((waited++))
    done

    # 强制立即同步一次
    chronyc makestep &>/dev/null 2>&1 || true

    sleep 2
    info "chrony 同步状态:"
    divider
    chronyc tracking 2>/dev/null || true
    echo ""
    chronyc sources -v 2>/dev/null || true
    divider

    SYNC_TOOL="chrony"
}

# ---------- ntpdate ----------
setup_ntpdate() {
    local installed=$1
    info "选择了 ntpdate"

    if [[ "$installed" == "false" ]]; then
        case "$PKG_MGR" in
            apt)        install_pkg ntpdate ;;
            yum|dnf)    install_pkg ntpdate ;;
            apk)        install_pkg ntpdate ;;
            pacman)     install_pkg ntp ;;
        esac
    fi

    stop_conflicting_services ""

    info "正在通过 ntpdate 同步时间..."
    divider
    local synced=false
    for server in "${NTP_SERVERS[@]}"; do
        echo -e "  尝试: ${CYAN}${server}${NC}"
        if ntpdate -u "$server" 2>&1; then
            synced=true
            info "已从 ${server} 同步成功"
            break
        fi
    done
    divider

    if ! $synced; then
        warn "NTP 服务器均失败，将在第三步通过 HTTP 校准"
    fi

    # 写入硬件时钟
    command -v hwclock &>/dev/null && hwclock -w 2>/dev/null || true

    SYNC_TOOL="ntpdate"
}

# ---------- systemd-timesyncd ----------
setup_timesyncd() {
    local installed=$1
    info "选择了 systemd-timesyncd"

    if [[ "$installed" == "false" ]]; then
        case "$PKG_MGR" in
            apt)    install_pkg systemd-timesyncd ;;
            yum|dnf)
                error "CentOS/RHEL 不提供 timesyncd，请重新选择"
                select_sync_tool
                return
                ;;
            apk)
                error "Alpine 不支持 timesyncd，请重新选择"
                select_sync_tool
                return
                ;;
            pacman) info "pacman 系统 systemd 已自带 timesyncd" ;;
        esac
    fi

    stop_conflicting_services "systemd-timesyncd"

    mkdir -p /etc/systemd/timesyncd.conf.d
    cat > /etc/systemd/timesyncd.conf.d/custom-ntp.conf <<EOF
[Time]
NTP=time.cloudflare.com time.google.com pool.ntp.org
FallbackNTP=time.apple.com ntp.aliyun.com
EOF

    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    timedatectl set-ntp true 2>/dev/null || true

    # 等待同步完成
    info "等待 timesyncd 同步..."
    sleep 5

    info "timesyncd 同步状态:"
    divider
    timedatectl timesync-status 2>/dev/null || timedatectl status 2>/dev/null
    divider

    SYNC_TOOL="timesyncd"
}

# ==================== 第三步：HTTP 大站获取时间并自动校准 ====================
http_time_sync() {
    header "第三步：从 HTTP 大站获取网络时间并校准"

    local sites=(
        "https://www.apple.com"
        "https://www.cloudflare.com"
        "https://www.google.com"
        "https://www.microsoft.com"
        "https://www.baidu.com"
    )

    local epoch_times=()

    echo ""
    echo -e "${BOLD}从各大站 HTTP Date 头获取时间：${NC}"
    divider

    for site in "${sites[@]}"; do
        local date_header
        date_header=$(curl -sI --max-time 5 "$site" 2>/dev/null | grep -i "^date:" | sed 's/[Dd]ate: //' | tr -d '\r')
        if [[ -n "$date_header" ]]; then
            local epoch
            epoch=$(date -d "$date_header" +%s 2>/dev/null)
            printf "  %-30s │ ${GREEN}%s${NC}\n" "$site" "$date_header"
            [[ -n "$epoch" ]] && epoch_times+=("$epoch")
        else
            printf "  %-30s │ ${RED}获取失败${NC}\n" "$site"
        fi
    done
    divider

    if [[ ${#epoch_times[@]} -eq 0 ]]; then
        error "无法从任何网站获取时间，跳过 HTTP 校时"
        return
    fi

    # 取中位数（抗异常值）
    IFS=$'\n' sorted_epochs=($(sort -n <<<"${epoch_times[*]}")); unset IFS
    local mid_idx=$(( ${#sorted_epochs[@]} / 2 ))
    local median_epoch="${sorted_epochs[$mid_idx]}"
    local median_time
    median_time=$(date -d "@${median_epoch}" "+%Y-%m-%d %H:%M:%S %Z")

    local current_epoch
    current_epoch=$(date +%s)
    local drift=$(( current_epoch - median_epoch ))
    local abs_drift=${drift#-}

    echo ""
    echo -e "  网络时间(中位数): ${BOLD}${median_time}${NC}"
    echo -e "  当前系统时间:     ${BOLD}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}"
    echo -e "  偏差:             ${BOLD}${drift} 秒${NC}"
    echo ""

    if [[ $abs_drift -gt 2 ]]; then
        warn "偏差超过 2 秒，自动校准中..."

        local set_time
        set_time=$(date -d "@${median_epoch}" "+%Y-%m-%d %H:%M:%S")

        # 如果用了持续同步的守护进程，先暂停以允许手动设置
        if [[ "${SYNC_TOOL:-}" == "chrony" ]]; then
            systemctl stop chronyd 2>/dev/null || systemctl stop chrony 2>/dev/null || true
        elif [[ "${SYNC_TOOL:-}" == "timesyncd" ]]; then
            timedatectl set-ntp false 2>/dev/null || true
            systemctl stop systemd-timesyncd 2>/dev/null || true
        fi

        # 设置时间
        if date -s "$set_time" &>/dev/null; then
            info "系统时间已校准为: ${BOLD}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}"
        elif timedatectl set-time "$set_time" &>/dev/null; then
            info "系统时间已校准为: ${BOLD}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}"
        else
            error "自动校准失败，请手动执行: date -s '${set_time}'"
        fi

        # 同步到硬件时钟
        command -v hwclock &>/dev/null && hwclock -w 2>/dev/null && info "已同步到硬件时钟"

        # 重新启动守护进程
        if [[ "${SYNC_TOOL:-}" == "chrony" ]]; then
            systemctl start chronyd 2>/dev/null || systemctl start chrony 2>/dev/null || true
        elif [[ "${SYNC_TOOL:-}" == "timesyncd" ]]; then
            systemctl start systemd-timesyncd 2>/dev/null || true
            timedatectl set-ntp true 2>/dev/null || true
        fi
    else
        info "偏差在 2 秒以内，时间准确 ✓"
    fi
}

# ==================== 最终汇总 ====================
show_summary() {
    header "校准完成 — 最终状态"

    local final_tz
    final_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "${DETECTED_TZ:-UTC}")

    echo ""
    echo -e "  ${BOLD}时区:${NC}         ${GREEN}${final_tz}${NC}"
    echo -e "  ${BOLD}校时工具:${NC}     ${GREEN}${SYNC_TOOL}${NC}"
    echo -e "  ${BOLD}当前时间:${NC}     ${GREEN}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}"
    echo -e "  ${BOLD}UTC 时间:${NC}     $(date -u "+%Y-%m-%d %H:%M:%S UTC")"
    echo -e "  ${BOLD}Epoch:${NC}        $(date +%s)"
    command -v hwclock &>/dev/null && echo -e "  ${BOLD}硬件时钟:${NC}     $(hwclock --show 2>/dev/null || echo 'N/A')"
    echo ""

    if command -v timedatectl &>/dev/null; then
        divider
        timedatectl status
        divider
    fi

    echo ""
    info "全部完成！系统时区和时间已校准。"
    echo ""
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   VPS 时区与时间自动校准脚本 v1.1       ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    detect_pkg_manager

    detect_timezone_by_ip      # 第一步
    select_sync_tool           # 第二步（安装后立即自动同步）
    http_time_sync             # 第三步（HTTP 验证+自动校准，无需确认）

    show_summary
}

main "$@"
