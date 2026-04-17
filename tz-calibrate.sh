#!/bin/bash

# ============================================================
# VPS 时区与时间自动校准脚本
# 功能：自动识别时区 → 选择校时工具 → 从网络大站获取时间并校准
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

# 检测包管理器
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache -y"
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
    info "检测到包管理器: ${BOLD}${PKG_MGR}${NC}"
}

# ==================== 第一步：根据公网IP确定时区 ====================
detect_timezone_by_ip() {
    header "第一步：根据公网 IP 自动检测时区"

    local public_ip=""
    local timezone=""

    # 获取公网 IP
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
        warn "无法获取公网 IP，将使用 UTC 作为默认时区"
        DETECTED_TZ="UTC"
        return
    fi

    # 通过 IP 查询时区
    info "正在通过 IP 查询所属时区..."
    local tz_services=(
        "http://ip-api.com/json/${public_ip}?fields=timezone,country,city,query"
        "https://ipapi.co/${public_ip}/json/"
        "https://ipwho.is/${public_ip}"
    )

    for svc in "${tz_services[@]}"; do
        local resp
        resp=$(curl -s --max-time 5 "$svc" 2>/dev/null)
        if [[ -n "$resp" ]]; then
            # 尝试提取 timezone 字段
            timezone=$(echo "$resp" | grep -oP '"timezone"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
            if [[ -n "$timezone" && "$timezone" == *"/"* ]]; then
                local country city
                country=$(echo "$resp" | grep -oP '"country"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
                city=$(echo "$resp" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null | head -1)
                info "查询结果:  国家=${BOLD}${country:-未知}${NC}  城市=${BOLD}${city:-未知}${NC}"
                info "检测时区:  ${BOLD}${timezone}${NC}"
                break
            fi
            timezone=""
        fi
    done

    if [[ -z "$timezone" ]]; then
        warn "无法通过 IP 确定时区，使用 UTC"
        timezone="UTC"
    fi

    DETECTED_TZ="$timezone"

    divider
    echo -e "  检测到的时区: ${GREEN}${BOLD}${DETECTED_TZ}${NC}"
    echo -e "  当前系统时区: ${YELLOW}$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '未知')${NC}"
    divider

    echo ""
    read -rp "$(echo -e "${CYAN}是否将系统时区设置为 ${BOLD}${DETECTED_TZ}${NC}${CYAN} ? [Y/n]: ${NC}")" confirm
    confirm="${confirm:-Y}"

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 设置时区
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone "$DETECTED_TZ"
        else
            ln -sf "/usr/share/zoneinfo/${DETECTED_TZ}" /etc/localtime
            echo "$DETECTED_TZ" > /etc/timezone
        fi
        info "时区已设置为: ${BOLD}${DETECTED_TZ}${NC}"
    else
        read -rp "$(echo -e "${CYAN}请手动输入时区 (如 Asia/Shanghai): ${NC}")" manual_tz
        if [[ -f "/usr/share/zoneinfo/${manual_tz}" ]]; then
            if command -v timedatectl &>/dev/null; then
                timedatectl set-timezone "$manual_tz"
            else
                ln -sf "/usr/share/zoneinfo/${manual_tz}" /etc/localtime
                echo "$manual_tz" > /etc/timezone
            fi
            DETECTED_TZ="$manual_tz"
            info "时区已设置为: ${BOLD}${manual_tz}${NC}"
        else
            error "无效时区: $manual_tz，保持当前时区不变"
        fi
    fi
}

# ==================== 第二步：选择校时工具 ====================
select_sync_tool() {
    header "第二步：选择时间同步工具"

    # 检测已安装状态
    local chrony_installed=false
    local ntpdate_installed=false
    local timesyncd_installed=false

    command -v chronyd &>/dev/null && chrony_installed=true
    command -v chronyc &>/dev/null && chrony_installed=true
    command -v ntpdate &>/dev/null && ntpdate_installed=true
    [[ -f /lib/systemd/system/systemd-timesyncd.service ]] && timesyncd_installed=true
    systemctl list-unit-files systemd-timesyncd.service &>/dev/null 2>&1 && timesyncd_installed=true

    local c_status y_status t_status
    $chrony_installed   && c_status="${GREEN}[已安装]${NC}" || c_status="${RED}[未安装]${NC}"
    $ntpdate_installed  && y_status="${GREEN}[已安装]${NC}" || y_status="${RED}[未安装]${NC}"
    $timesyncd_installed && t_status="${GREEN}[已安装]${NC}" || t_status="${RED}[未安装]${NC}"

    echo ""
    echo -e "${BOLD}┌─────┬────────────────────┬──────────┬───────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│ 编号│ 工具名称           │ 安装状态 │ 说明                                              │${NC}"
    echo -e "${BOLD}├─────┼────────────────────┼──────────┼───────────────────────────────────────────────────┤${NC}"
    echo -e "│  1  │ ${CYAN}chrony (chronyc)${NC}  │ $c_status  │ 现代 NTP 客户端/服务端，精度高，适合虚拟机与     │"
    echo -e "│     │                    │          │ 容器环境。支持突发校时+渐进调整，启动快、内存少。 │"
    echo -e "│     │                    │          │ ${GREEN}★ 推荐用于生产服务器${NC}                              │"
    echo -e "├─────┼────────────────────┼──────────┼───────────────────────────────────────────────────┤${NC}"
    echo -e "│  2  │ ${CYAN}ntpdate${NC}            │ $y_status  │ 传统一次性时间同步工具，立即将系统时间跳变到     │"
    echo -e "│     │                    │          │ NTP 服务器时间。不作为守护进程运行，仅单次校时。   │"
    echo -e "│     │                    │          │ ${YELLOW}⚠ 已被弃用，适合临时手动校时${NC}                      │"
    echo -e "├─────┼────────────────────┼──────────┼───────────────────────────────────────────────────┤${NC}"
    echo -e "│  3  │ ${CYAN}systemd-timesyncd${NC}  │ $t_status  │ systemd 内置轻量级 SNTP 客户端，仅做客户端同步。 │"
    echo -e "│     │                    │          │ 配置简单、资源占用最小，适合桌面/轻量VPS。         │"
    echo -e "│     │                    │          │ ${BLUE}◆ 适合不需要高精度的场景${NC}                          │"
    echo -e "${BOLD}└─────┴────────────────────┴──────────┴───────────────────────────────────────────────────┘${NC}"

    echo ""
    echo -e "${BOLD}三者核心区别：${NC}"
    divider
    echo -e "  ${CYAN}chrony${NC}     ─ 精度最高(微秒级)，支持间歇性网络，既是客户端也可当服务端"
    echo -e "  ${CYAN}ntpdate${NC}    ─ 一次性跳变校时，无守护进程，校完即退出，不持续同步"
    echo -e "  ${CYAN}timesyncd${NC}  ─ 最轻量(systemd自带)，仅SNTP客户端，精度毫秒级，功能最少"
    divider
    echo ""

    read -rp "$(echo -e "${CYAN}请选择校时工具 [1/2/3] (默认1): ${NC}")" tool_choice
    tool_choice="${tool_choice:-1}"

    case "$tool_choice" in
        1) setup_chrony "$chrony_installed" ;;
        2) setup_ntpdate "$ntpdate_installed" ;;
        3) setup_timesyncd "$timesyncd_installed" ;;
        *) error "无效选择"; exit 1 ;;
    esac
}

# NTP 服务器池
NTP_SERVERS=(
    "pool.ntp.org"
    "time.cloudflare.com"
    "time.google.com"
    "time.apple.com"
    "ntp.aliyun.com"
)

# ---------- chrony ----------
setup_chrony() {
    local installed=$1
    info "选择了 chrony"

    if [[ "$installed" == "false" ]]; then
        warn "chrony 未安装，正在安装..."
        $PKG_UPDATE &>/dev/null
        case "$PKG_MGR" in
            apt)    $PKG_INSTALL chrony ;;
            yum|dnf) $PKG_INSTALL chrony ;;
            apk)    $PKG_INSTALL chrony ;;
            pacman) $PKG_INSTALL chrony ;;
        esac
        info "chrony 安装完成"
    fi

    # 停止冲突服务
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true

    # 配置 chrony
    local chrony_conf
    if [[ -f /etc/chrony/chrony.conf ]]; then
        chrony_conf="/etc/chrony/chrony.conf"
    elif [[ -f /etc/chrony.conf ]]; then
        chrony_conf="/etc/chrony.conf"
    else
        chrony_conf="/etc/chrony/chrony.conf"
        mkdir -p /etc/chrony
    fi

    info "备份并写入 chrony 配置: $chrony_conf"
    [[ -f "$chrony_conf" ]] && cp "$chrony_conf" "${chrony_conf}.bak.$(date +%s)"

    cat > "$chrony_conf" <<EOF
# VPS 时间同步配置 - 自动生成于 $(date)
# NTP 服务器池
server pool.ntp.org        iburst
server time.cloudflare.com iburst
server time.google.com     iburst
server time.apple.com      iburst
server ntp.aliyun.com      iburst

# 如果时间偏差超过1秒，前3次同步允许跳变
makestep 1.0 3

# 记录时间偏移
driftfile /var/lib/chrony/drift

# 开启 RTC 同步
rtcsync

# 日志
logdir /var/log/chrony
EOF

    # 启动服务
    systemctl enable chronyd 2>/dev/null || systemctl enable chrony 2>/dev/null
    systemctl restart chronyd 2>/dev/null || systemctl restart chrony 2>/dev/null

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
        warn "ntpdate 未安装，正在安装..."
        $PKG_UPDATE &>/dev/null
        case "$PKG_MGR" in
            apt)    $PKG_INSTALL ntpdate ;;
            yum|dnf) $PKG_INSTALL ntpdate ;;
            apk)    $PKG_INSTALL ntpdate ;;  # Alpine 可能在 openntpd 包中
            pacman) $PKG_INSTALL ntp ;;
        esac
        info "ntpdate 安装完成"
    fi

    # 停止可能冲突的 NTP 守护进程
    systemctl stop chronyd 2>/dev/null || true
    systemctl stop ntp 2>/dev/null || true
    systemctl stop ntpd 2>/dev/null || true
    systemctl stop systemd-timesyncd 2>/dev/null || true

    info "正在通过 ntpdate 同步时间..."
    divider
    local synced=false
    for server in "${NTP_SERVERS[@]}"; do
        echo -e "  尝试服务器: ${CYAN}${server}${NC}"
        if ntpdate -u "$server" 2>&1; then
            synced=true
            info "成功从 ${server} 同步时间"
            break
        fi
    done
    divider

    if ! $synced; then
        warn "所有 NTP 服务器均失败，将在第三步使用 HTTP 时间"
    fi

    SYNC_TOOL="ntpdate"
}

# ---------- systemd-timesyncd ----------
setup_timesyncd() {
    local installed=$1
    info "选择了 systemd-timesyncd"

    if [[ "$installed" == "false" ]]; then
        warn "systemd-timesyncd 未安装，正在安装..."
        $PKG_UPDATE &>/dev/null
        case "$PKG_MGR" in
            apt)    $PKG_INSTALL systemd-timesyncd ;;
            yum|dnf)
                warn "CentOS/RHEL 默认不提供 timesyncd，建议使用 chrony"
                error "无法在当前系统安装 timesyncd，请选择其他工具"
                select_sync_tool
                return
                ;;
            apk)
                warn "Alpine 不支持 systemd-timesyncd，请选择其他工具"
                select_sync_tool
                return
                ;;
            pacman) $PKG_INSTALL systemd ;;
        esac
    fi

    # 停止冲突服务
    systemctl stop chronyd 2>/dev/null || true
    systemctl disable chronyd 2>/dev/null || true
    systemctl stop ntp 2>/dev/null || true
    systemctl disable ntp 2>/dev/null || true

    # 配置 timesyncd
    local conf_dir="/etc/systemd/timesyncd.conf.d"
    mkdir -p "$conf_dir"

    cat > "${conf_dir}/custom-ntp.conf" <<EOF
# VPS 时间同步配置 - 自动生成于 $(date)
[Time]
NTP=time.cloudflare.com time.google.com pool.ntp.org
FallbackNTP=time.apple.com ntp.aliyun.com
EOF

    # 启动服务
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd

    # 启用 NTP 同步
    timedatectl set-ntp true 2>/dev/null || true

    sleep 2

    info "timesyncd 同步状态:"
    divider
    timedatectl timesync-status 2>/dev/null || timedatectl status 2>/dev/null
    divider

    SYNC_TOOL="timesyncd"
}

# ==================== 第三步：从 HTTP 大站获取时间验证/校准 ====================
http_time_sync() {
    header "第三步：从 HTTP 大站获取网络时间验证"

    local sites=(
        "https://www.apple.com"
        "https://www.cloudflare.com"
        "https://www.google.com"
        "https://www.microsoft.com"
        "https://www.baidu.com"
    )

    local http_times=()
    local epoch_times=()

    echo ""
    echo -e "${BOLD}从各大站 HTTP 响应头获取 Date 时间：${NC}"
    divider

    for site in "${sites[@]}"; do
        local date_header
        date_header=$(curl -sI --max-time 5 "$site" 2>/dev/null | grep -i "^date:" | sed 's/[Dd]ate: //' | tr -d '\r')
        if [[ -n "$date_header" ]]; then
            # 转换为 epoch
            local epoch
            epoch=$(date -d "$date_header" +%s 2>/dev/null)
            local local_fmt
            local_fmt=$(date -d "$date_header" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)

            printf "  %-30s │ %s\n" "$site" "${GREEN}${date_header}${NC}"
            if [[ -n "$epoch" ]]; then
                epoch_times+=("$epoch")
                http_times+=("$date_header")
            fi
        else
            printf "  %-30s │ %s\n" "$site" "${RED}获取失败${NC}"
        fi
    done
    divider

    if [[ ${#epoch_times[@]} -eq 0 ]]; then
        error "无法从任何网站获取时间，跳过 HTTP 校时"
        return
    fi

    # 计算中位数时间（排序取中间值，避免异常值干扰）
    IFS=$'\n' sorted_epochs=($(sort -n <<<"${epoch_times[*]}")); unset IFS
    local mid_idx=$(( ${#sorted_epochs[@]} / 2 ))
    local median_epoch="${sorted_epochs[$mid_idx]}"
    local median_time
    median_time=$(date -d "@${median_epoch}" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)

    local current_epoch
    current_epoch=$(date +%s)
    local drift=$(( current_epoch - median_epoch ))
    local abs_drift=${drift#-}

    echo ""
    echo -e "  HTTP 中位数时间: ${BOLD}${median_time}${NC}  (epoch: ${median_epoch})"
    echo -e "  当前系统时间:    ${BOLD}$(date "+%Y-%m-%d %H:%M:%S %Z")${NC}  (epoch: ${current_epoch})"
    echo -e "  时间偏差:        ${BOLD}${drift} 秒${NC}"
    echo ""

    if [[ $abs_drift -gt 3 ]]; then
        warn "系统时间与网络时间偏差超过 3 秒 (${drift}s)"
        read -rp "$(echo -e "${CYAN}是否使用 HTTP 获取的时间强制校准系统时钟？[Y/n]: ${NC}")" force_sync
        force_sync="${force_sync:-Y}"

        if [[ "$force_sync" =~ ^[Yy]$ ]]; then
            # 使用中位数时间来设置
            local set_time
            set_time=$(date -d "@${median_epoch}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)

            # 先尝试用 date 命令直接设置
            if date -s "$set_time" &>/dev/null; then
                info "系统时间已通过 HTTP 时间校准为: $(date "+%Y-%m-%d %H:%M:%S %Z")"
            elif timedatectl set-time "$set_time" &>/dev/null; then
                info "系统时间已通过 timedatectl 校准为: $(date "+%Y-%m-%d %H:%M:%S %Z")"
            else
                error "无法设置系统时间，请手动执行: date -s '${set_time}'"
            fi

            # 同步到硬件时钟
            if command -v hwclock &>/dev/null; then
                hwclock -w 2>/dev/null && info "已同步到硬件时钟 (RTC)"
            fi
        fi
    else
        info "系统时间与网络时间偏差在 3 秒以内，无需额外校准 ✓"
    fi
}

# ==================== 最终汇总 ====================
show_summary() {
    header "校准完成 — 最终状态"

    echo ""
    echo -e "  ${BOLD}时区:${NC}         $(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "$DETECTED_TZ")"
    echo -e "  ${BOLD}校时工具:${NC}     ${SYNC_TOOL}"
    echo -e "  ${BOLD}当前时间:${NC}     $(date "+%Y-%m-%d %H:%M:%S %Z")"
    echo -e "  ${BOLD}UTC 时间:${NC}     $(date -u "+%Y-%m-%d %H:%M:%S UTC")"
    echo -e "  ${BOLD}Epoch:${NC}        $(date +%s)"

    if command -v hwclock &>/dev/null; then
        echo -e "  ${BOLD}硬件时钟:${NC}     $(hwclock --show 2>/dev/null || echo 'N/A')"
    fi

    echo ""

    # timedatectl 完整输出
    if command -v timedatectl &>/dev/null; then
        divider
        timedatectl status
        divider
    fi

    echo ""
    info "所有操作完成！"
    echo ""
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║   VPS 时区与时间自动校准脚本 v1.0       ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    detect_pkg_manager

    # 第一步：检测并设置时区
    detect_timezone_by_ip

    # 第二步：选择并配置校时工具
    select_sync_tool

    # 第三步：HTTP 时间验证/校准
    http_time_sync

    # 汇总
    show_summary
}

main "$@"
