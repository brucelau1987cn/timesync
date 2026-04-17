#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# 根据公网 IP 归属地自动调整时区并同步时间
# 使用 chronyd 工具同步
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash tz-chronyd.sh
# ============================================================

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 全局变量
PUBLIC_IP=""
COUNTRY=""
CITY=""
REGION=""
ORG=""
DETECTED_TZ=""

# 日志函数
log_info()  { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "  ${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "  ${RED}[FAIL]${NC}  $1"; }

separator() {
    echo -e "${CYAN}================================================================${NC}"
}

#================================================================
# 检测包管理器并安装软件
#================================================================
install_package() {
    local pkg="$1"
    log_info "正在安装 ${pkg}..."

    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "$pkg" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg" >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add --quiet "$pkg" >/dev/null 2>&1
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --quiet "$pkg" >/dev/null 2>&1
    else
        log_error "未识别的包管理器，无法安装 ${pkg}"
        return 1
    fi

    if [[ $? -eq 0 ]]; then
        log_ok "${pkg} 安装成功"
        return 0
    else
        log_error "${pkg} 安装失败"
        return 1
    fi
}

#================================================================
# 第一阶段：获取公网IP和时区信息
#================================================================
stage_get_info() {
    echo ""
    separator
    echo -e "${CYAN}  [阶段一] 获取公网IP和时区信息${NC}"
    separator
    echo ""

    log_info "正在获取公网IPv4地址..."
    PUBLIC_IP=$(curl -4 -s --max-time 10 ip.sb 2>/dev/null)
    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "ip.sb 失败，尝试 ifconfig.me..."
        PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null)
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        log_warn "ifconfig.me 失败，尝试 ipinfo.io..."
        PUBLIC_IP=$(curl -4 -s --max-time 10 https://ipinfo.io/ip 2>/dev/null)
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "所有方法均无法获取公网IP，脚本退出"
        exit 1
    fi
    log_ok "公网IPv4: ${GREEN}${PUBLIC_IP}${NC}"

    log_info "正在查询IP归属信息 (ipinfo.io/${PUBLIC_IP})..."
    local raw_json=""
    raw_json=$(curl -s --max-time 15 "https://ipinfo.io/${PUBLIC_IP}" 2>/dev/null)

    if [[ -z "$raw_json" ]]; then
        log_error "无法从 ipinfo.io 获取信息，脚本退出"
        exit 1
    fi

    if command -v jq &>/dev/null; then
        DETECTED_TZ=$(echo "$raw_json" | jq -r '.timezone // empty')
        COUNTRY=$(echo "$raw_json" | jq -r '.country // empty')
        CITY=$(echo "$raw_json" | jq -r '.city // empty')
        REGION=$(echo "$raw_json" | jq -r '.region // empty')
        ORG=$(echo "$raw_json" | jq -r '.org // empty')
    else
        DETECTED_TZ=$(echo "$raw_json" | grep -oP '"timezone"\s*:\s*"\K[^"]+' 2>/dev/null)
        COUNTRY=$(echo "$raw_json" | grep -oP '"country"\s*:\s*"\K[^"]+' 2>/dev/null)
        CITY=$(echo "$raw_json" | grep -oP '"city"\s*:\s*"\K[^"]+' 2>/dev/null)
        REGION=$(echo "$raw_json" | grep -oP '"region"\s*:\s*"\K[^"]+' 2>/dev/null)
        ORG=$(echo "$raw_json" | grep -oP '"org"\s*:\s*"\K[^"]+' 2>/dev/null)
    fi

    if [[ -z "$DETECTED_TZ" ]]; then
        log_error "无法解析时区信息，脚本退出"
        exit 1
    fi

    log_ok "检测时区: ${GREEN}${DETECTED_TZ}${NC}"
    log_ok "归属地区: ${GREEN}${COUNTRY} / ${REGION} / ${CITY}${NC}"
    [[ -n "$ORG" ]] && log_ok "网络运营: ${GREEN}${ORG}${NC}"
    echo ""
}

#================================================================
# 第二阶段：配置系统时区
#================================================================
stage_set_timezone() {
    separator
    echo -e "${CYAN}  [阶段二] 配置系统时区${NC}"
    separator
    echo ""

    local tz="$DETECTED_TZ"

    local current_tz=""
    if command -v timedatectl &>/dev/null; then
        current_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    fi
    if [[ -z "$current_tz" ]] && [[ -f /etc/timezone ]]; then
        current_tz=$(cat /etc/timezone 2>/dev/null)
    fi
    if [[ -z "$current_tz" ]]; then
        current_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')
    fi

    log_info "当前时区: ${YELLOW}${current_tz:-未知}${NC}"
    log_info "目标时区: ${GREEN}${tz}${NC}"

    if [[ "$current_tz" == "$tz" ]]; then
        log_ok "时区已正确，无需修改"
        echo ""
        return 0
    fi

    if [[ ! -f "/usr/share/zoneinfo/${tz}" ]]; then
        log_error "时区文件不存在: /usr/share/zoneinfo/${tz}"
        exit 1
    fi

    if command -v timedatectl &>/dev/null; then
        if timedatectl set-timezone "$tz" 2>/dev/null; then
            log_ok "timedatectl 设置成功: ${GREEN}${tz}${NC}"
            echo ""
            return 0
        fi
        log_warn "timedatectl 设置失败，使用链接方式"
    fi

    rm -f /etc/localtime 2>/dev/null
    ln -s "/usr/share/zoneinfo/${tz}" /etc/localtime
    echo "$tz" > /etc/timezone 2>/dev/null || true

    local verify_tz=""
    verify_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')
    if [[ "$verify_tz" == "$tz" ]]; then
        log_ok "链接方式设置成功: ${GREEN}${tz}${NC}"
    else
        log_error "时区设置失败"
    fi
    echo ""
}

#================================================================
# 第三阶段：NTP时间同步
#================================================================
stage_sync_time() {
    separator
    echo -e "${CYAN}  [阶段三] NTP时间同步${NC}"
    separator
    echo ""

    local tz="$DETECTED_TZ"

    # ---- 选择NTP服务器 ----
    log_info "根据时区选择最优NTP服务器..."

    local ntp_primary=""
    local ntp_secondary=""
    local ntp_tertiary=""

    case "$tz" in
        Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi)
            ntp_primary="cn.pool.ntp.org"
            ntp_secondary="ntp.aliyun.com"
            ntp_tertiary="ntp.tencent.com"
            ;;
        Asia/Hong_Kong)
            ntp_primary="hk.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Tokyo)
            ntp_primary="jp.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Seoul)
            ntp_primary="kr.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Singapore)
            ntp_primary="sg.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Taipei)
            ntp_primary="tw.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Kolkata|Asia/Calcutta)
            ntp_primary="in.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/Bangkok|Asia/Ho_Chi_Minh|Asia/Jakarta|Asia/Manila)
            ntp_primary="asia.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Asia/*)
            ntp_primary="asia.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Europe/London)
            ntp_primary="uk.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Europe/Berlin|Europe/Paris|Europe/Amsterdam)
            ntp_primary="de.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Europe/Moscow)
            ntp_primary="ru.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Europe/*)
            ntp_primary="europe.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        America/New_York|America/Chicago|America/Denver|America/Los_Angeles)
            ntp_primary="us.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        America/Toronto|America/Vancouver)
            ntp_primary="ca.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        America/Sao_Paulo)
            ntp_primary="br.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        America/*)
            ntp_primary="north-america.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Australia/*|Pacific/*)
            ntp_primary="oceania.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        Africa/*)
            ntp_primary="africa.pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
        *)
            ntp_primary="pool.ntp.org"
            ntp_secondary="time.google.com"
            ntp_tertiary="time.cloudflare.com"
            ;;
    esac

    log_ok "主NTP: ${GREEN}${ntp_primary}${NC}"
    log_ok "备NTP: ${GREEN}${ntp_secondary}${NC}"
    log_ok "三NTP: ${GREEN}${ntp_tertiary}${NC}"
    echo ""

    # ---- 检测同步工具，没有就自动安装 ----
    local sync_tool=""

    if command -v chronyd &>/dev/null; then
        sync_tool="chrony"
    elif command -v ntpdate &>/dev/null; then
        sync_tool="ntpdate"
    elif command -v ntpd &>/dev/null; then
        sync_tool="ntpd"
    else
        log_warn "未检测到NTP工具，正在自动安装 chrony..."
        echo ""
        if install_package "chrony"; then
            sync_tool="chrony"
        else
            log_warn "chrony 安装失败，尝试安装 ntpdate..."
            if install_package "ntpdate"; then
                sync_tool="ntpdate"
            else
                log_warn "ntpdate 安装失败，尝试安装 ntp..."
                if install_package "ntp"; then
                    sync_tool="ntpd"
                else
                    sync_tool="http"
                    log_warn "所有NTP工具安装失败，将使用HTTP方式同步"
                fi
            fi
        fi
        echo ""
    fi

    log_info "同步工具: ${GREEN}${sync_tool}${NC}"

    local time_before
    time_before=$(date '+%Y-%m-%d %H:%M:%S')
    log_info "同步前时间: ${YELLOW}${time_before}${NC}"
    echo ""

    local sync_ok=false

    # ---- 执行同步 ----
    case "$sync_tool" in
        chrony)
            log_info "配置 Chrony..."

            # ---- 停掉 systemd-timesyncd 避免冲突 ----
            if systemctl is-active systemd-timesyncd &>/dev/null; then
                log_info "停止 systemd-timesyncd 避免冲突..."
                systemctl stop systemd-timesyncd 2>/dev/null || true
                systemctl disable systemd-timesyncd 2>/dev/null || true
                systemctl mask systemd-timesyncd 2>/dev/null || true
                log_ok "systemd-timesyncd 已停止"
            fi

            local chrony_conf="/etc/chrony/chrony.conf"
            if [[ ! -d "/etc/chrony" ]]; then
                if [[ -f "/etc/chrony.conf" ]]; then
                    chrony_conf="/etc/chrony.conf"
                else
                    mkdir -p /etc/chrony 2>/dev/null
                fi
            fi

            if [[ -f "$chrony_conf" ]]; then
                cp "$chrony_conf" "${chrony_conf}.bak" 2>/dev/null || true
            fi

            {
                echo "# Auto-generated by vps-time-sync"
                echo "server ${ntp_primary} iburst"
                echo "server ${ntp_secondary} iburst"
                echo "server ${ntp_tertiary} iburst"
                echo ""
                echo "driftfile /var/lib/chrony/chrony.drift"
                echo "makestep 1.0 3"
                echo "rtcsync"
            } > "$chrony_conf"

            log_ok "配置已写入: ${chrony_conf}"

            systemctl stop chronyd 2>/dev/null || true
            sleep 1
            systemctl enable chronyd 2>/dev/null || true
            systemctl start chronyd 2>/dev/null || true

            # ---- 让 timedatectl 识别 NTP 服务 ----
            timedatectl set-ntp true 2>/dev/null || true

            log_info "等待 Chrony 同步（5秒）..."
            sleep 5

            if chronyc -a makestep >/dev/null 2>&1; then
                sync_ok=true
                log_ok "Chrony makestep 执行成功"
            else
                log_warn "chronyc makestep 返回异常，检查状态..."
            fi

            sleep 2

            echo ""
            log_info "Chrony 同步源:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            chronyc sources 2>/dev/null | while IFS= read -r line; do
                echo -e "  $line"
            done
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"

            echo ""
            log_info "Chrony tracking:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            chronyc tracking 2>/dev/null | while IFS= read -r line; do
                echo -e "  $line"
            done
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ;;

        ntpdate)
            log_info "使用 ntpdate 单次同步..."

            # ---- 停掉冲突服务 ----
            systemctl stop systemd-timesyncd 2>/dev/null || true
            systemctl disable systemd-timesyncd 2>/dev/null || true

            for srv in "$ntp_primary" "$ntp_secondary" "$ntp_tertiary"; do
                log_info "尝试 ${srv}..."
                local ntpdate_output=""
                ntpdate_output=$(ntpdate -b "$srv" 2>&1)
                if [[ $? -eq 0 ]]; then
                    sync_ok=true
                    log_ok "ntpdate 同步成功 (${srv})"
                    echo -e "         ${ntpdate_output}"
                    break
                else
                    log_warn "${srv} 失败: ${ntpdate_output}"
                fi
            done
            ;;

        ntpd)
            log_info "配置 NTPD..."

            # ---- 停掉冲突服务 ----
            systemctl stop systemd-timesyncd 2>/dev/null || true
            systemctl disable systemd-timesyncd 2>/dev/null || true
            systemctl stop ntpd 2>/dev/null || true

            if [[ -f /etc/ntp.conf ]]; then
                cp /etc/ntp.conf /etc/ntp.conf.bak 2>/dev/null || true
            fi

            {
                echo "# Auto-generated by vps-time-sync"
                echo "driftfile /var/lib/ntp/drift"
                echo "restrict default kod nomodify notrap nopeer noquery"
                echo "restrict 127.0.0.1"
                echo ""
                echo "server ${ntp_primary} iburst prefer"
                echo "server ${ntp_secondary} iburst"
                echo "server ${ntp_tertiary} iburst"
            } > /etc/ntp.conf

            log_ok "配置已写入: /etc/ntp.conf"
            systemctl enable ntpd 2>/dev/null || true
            systemctl start ntpd 2>/dev/null || true
            log_info "等待 NTPD 同步（5秒）..."
            sleep 5
            sync_ok=true

            echo ""
            log_info "NTP peers:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ntpq -p 2>/dev/null | while IFS= read -r line; do
                echo -e "  $line"
            done
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ;;

        http)
            log_warn "使用HTTP方式获取时间（精度较低）..."
            for url in "https://www.google.com" "https://www.cloudflare.com" "https://www.baidu.com"; do
                local http_date=""
                http_date=$(curl -sI --max-time 5 "$url" 2>/dev/null | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //i' | tr -d '\r')
                if [[ -n "$http_date" ]]; then
                    log_info "获取到HTTP时间: ${http_date}"
                    if date -s "$http_date" >/dev/null 2>&1; then
                        sync_ok=true
                        log_ok "HTTP时间同步成功 (${url})"
                        break
                    else
                        log_warn "date -s 设置失败"
                    fi
                fi
            done
            ;;
    esac

    # ---- HTTP兜底 ----
    if [[ "$sync_ok" != "true" ]] && [[ "$sync_tool" != "http" ]]; then
        echo ""
        log_warn "NTP同步未成功，尝试HTTP方式兜底..."
        for url in "https://www.google.com" "https://www.cloudflare.com" "https://www.baidu.com"; do
            local http_date=""
            http_date=$(curl -sI --max-time 5 "$url" 2>/dev/null | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //i' | tr -d '\r')
            if [[ -n "$http_date" ]]; then
                log_info "HTTP时间: ${http_date}"
                if date -s "$http_date" >/dev/null 2>&1; then
                    sync_ok=true
                    log_ok "HTTP兜底同步成功 (${url})"
                    break
                fi
            fi
        done
    fi

    # ---- 写入硬件时钟 ----
    echo ""
    if command -v hwclock &>/dev/null; then
        hwclock --systohc 2>/dev/null || true
        log_info "已写入硬件时钟"
    fi

    local time_after
    time_after=$(date '+%Y-%m-%d %H:%M:%S')
    echo ""
    log_info "同步前: ${YELLOW}${time_before}${NC}"
    log_info "同步后: ${GREEN}${time_after}${NC}"
    echo ""

    if [[ "$sync_ok" == "true" ]]; then
        log_ok "时间同步完成！"
    else
        log_error "时间同步失败，请手动检查网络连接"
        log_info "手动同步命令: ntpdate -b pool.ntp.org"
    fi
    echo ""
}

#================================================================
# 第四阶段：结果汇总
#================================================================
stage_show_result() {
    separator
    echo -e "${CYAN}  [阶段四] 同步结果汇总${NC}"
    separator

    echo ""
    echo -e "  ${GREEN}+----------------------------------------------------------+${NC}"
    echo -e "  ${GREEN}|                    时间校准结果                           |${NC}"
    echo -e "  ${GREEN}+----------------------------------------------------------+${NC}"

    echo ""
    echo -e "  ${YELLOW}[IP信息]${NC}"
    echo -e "     公网IP:      ${GREEN}${PUBLIC_IP}${NC}"
    echo -e "     国家/地区:   ${GREEN}${COUNTRY}${NC}"
    echo -e "     区域:        ${GREEN}${REGION}${NC}"
    echo -e "     城市:        ${GREEN}${CITY}${NC}"
    [[ -n "$ORG" ]] && echo -e "     运营商:      ${GREEN}${ORG}${NC}"

    echo ""
    echo -e "  ${YELLOW}[时区信息]${NC}"
    echo -e "     设定时区:    ${GREEN}${DETECTED_TZ}${NC}"
    echo -e "     时区缩写:    ${GREEN}$(date +'%Z')${NC}"
    echo -e "     UTC偏移:     ${GREEN}$(date +'%z')${NC}"

    echo ""
    echo -e "  ${YELLOW}[当前时间]${NC}"
    echo -e "     本地时间:    ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    echo -e "     UTC时间:     ${GREEN}$(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
    echo -e "     星期:        ${GREEN}$(date '+%A')${NC}"

    if command -v timedatectl &>/dev/null; then
        echo ""
        echo -e "  ${YELLOW}[timedatectl 状态]${NC}"
        timedatectl status 2>/dev/null | while IFS= read -r line; do
            echo -e "     ${line}"
        done
    fi

    echo ""
    echo -e "  ${GREEN}+----------------------------------------------------------+${NC}"
    echo -e "  ${GREEN}|                    校准完成！                             |${NC}"
    echo -e "  ${GREEN}+----------------------------------------------------------+${NC}"

    echo ""
    echo -e "  ${CYAN}[后续命令]${NC}"
    echo "     查看时区:     timedatectl"
    echo "     Chrony状态:   chronyc tracking"
    echo "     Chrony源:     chronyc sources -v"
    echo "     手动同步:     chronyc makestep"
    echo ""
}

#================================================================
# 主函数
#================================================================
main() {
    clear
    echo ""
    separator
    echo -e "${CYAN}          VPS 时区和时间自动校准脚本${NC}"
    echo -e "${CYAN}      Auto Timezone & Time Calibration${NC}"
    separator

    if [[ $EUID -ne 0 ]]; then
        echo ""
        log_error "请使用 root 权限运行: sudo bash $0"
        exit 1
    fi

    stage_get_info
    stage_set_timezone
    stage_sync_time
    stage_show_result
}

main "$@"
