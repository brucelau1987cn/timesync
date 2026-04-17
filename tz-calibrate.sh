#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# 根据公网 IP 归属地自动调整时区并同步时间
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash tz-calibrate.sh
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
# 第一阶段：获取公网IP和时区信息
#================================================================
stage_get_info() {
    echo ""
    separator
    echo -e "${CYAN}  [阶段一] 获取公网IP和时区信息${NC}"
    separator
    echo ""

    # 1. 获取公网IPv4
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

    # 2. 通过 ipinfo.io 查询完整信息
    log_info "正在查询IP归属信息..."
    local raw_json=""
    raw_json=$(curl -s --max-time 15 "https://ipinfo.io/${PUBLIC_IP}" 2>/dev/null)

    if [[ -z "$raw_json" ]]; then
        log_error "无法从 ipinfo.io 获取信息，脚本退出"
        exit 1
    fi

    # 3. 解析JSON
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

    # 获取当前时区
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

    # 检查目标时区文件是否存在
    if [[ ! -f "/usr/share/zoneinfo/${tz}" ]]; then
        log_error "时区文件不存在: /usr/share/zoneinfo/${tz}"
        exit 1
    fi

    # 方法1: timedatectl
    if command -v timedatectl &>/dev/null; then
        if timedatectl set-timezone "$tz" 2>/dev/null; then
            log_ok "timedatectl 设置成功: ${GREEN}${tz}${NC}"
            echo ""
            return 0
        fi
        log_warn "timedatectl 设置失败，使用链接方式"
    fi

    # 方法2: 手动链接
    rm -f /etc/localtime 2>/dev/null
    ln -s "/usr/share/zoneinfo/${tz}" /etc/localtime
    echo "$tz" > /etc/timezone 2>/dev/null || true

    # 验证
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

    log_ok "主NTP服务器: ${GREEN}${ntp_primary}${NC}"
    log_ok "备NTP服务器: ${GREEN}${ntp_secondary}${NC}"
    log_ok "三NTP服务器: ${GREEN}${ntp_tertiary}${NC}"
    echo ""

    # ---- 检测同步工具 ----
    local sync_tool=""
    if command -v chronyd &>/dev/null; then
        sync_tool="chrony"
    elif command -v ntpd &>/dev/null; then
        sync_tool="ntpd"
    elif command -v ntpdate &>/dev/null; then
        sync_tool="ntpdate"
    elif command -v sntp &>/dev/null; then
        sync_tool="sntp"
    else
        sync_tool="http"
    fi
    log_info "同步工具: ${GREEN}${sync_tool}${NC}"

    # 记录同步前时间
    local time_before
    time_before=$(date '+%Y-%m-%d %H:%M:%S')
    log_info "同步前时间: ${YELLOW}${time_before}${NC}"
    echo ""

    local sync_ok=false

    # ---- 执行同步 ----
    case "$sync_tool" in
        chrony)
            log_info "配置 Chrony..."

            # 查找chrony配置文件路径
            local chrony_conf="/etc/chrony/chrony.conf"
            if [[ ! -d "/etc/chrony" ]]; then
                chrony_conf="/etc/chrony.conf"
            fi

            # 备份原配置
            if [[ -f "$chrony_conf" ]]; then
                cp "$chrony_conf" "${chrony_conf}.bak.$(date +%s)" 2>/dev/null || true
            fi

            # 写入新配置（不用heredoc变量展开，手动拼接）
            {
                echo "# Auto-generated by vps-time-sync"
                echo "server ${ntp_primary} iburst"
                echo "server ${ntp_secondary} iburst"
                echo "server ${ntp_tertiary} iburst"
                echo ""
                echo "driftfile /var/lib/chrony/chrony.drift"
                echo "makestep 1.0 3"
                echo "rtcsync"
                echo "allow all"
            } > "$chrony_conf"

            log_ok "Chrony 配置已写入: ${chrony_conf}"

            systemctl enable chronyd 2>/dev/null || true
            systemctl restart chronyd 2>/dev/null || true
            log_info "等待 Chrony 同步（5秒）..."
            sleep 5

            if chronyc makestep >/dev/null 2>&1; then
                sync_ok=true
                log_ok "Chrony makestep 执行成功"
            fi

            # 显示chrony源状态
            echo ""
            log_info "Chrony 同步源状态:"
            chronyc sources 2>/dev/null | while IFS= read -r line; do
                echo -e "         ${line}"
            done
            echo ""
            log_info "Chrony tracking 信息:"
            chronyc tracking 2>/dev/null | while IFS= read -r line; do
                echo -e "         ${line}"
            done
            ;;

        ntpd)
            log_info "配置 NTPD..."
            systemctl stop ntpd 2>/dev/null || true

            if [[ -f /etc/ntp.conf ]]; then
                cp /etc/ntp.conf /etc/ntp.conf.bak.$(date +%s) 2>/dev/null || true
            fi

            {
                echo "# Auto-generated by vps-time-sync"
                echo "driftfile /var/lib/ntp/drift"
                echo "restrict default kod nomodify notrap nopeer noquery"
                echo "restrict -6 default kod nomodify notrap nopeer noquery"
                echo "restrict 127.0.0.1"
                echo "restrict -6 ::1"
                echo ""
                echo "server ${ntp_primary} iburst prefer"
                echo "server ${ntp_secondary} iburst"
                echo "server ${ntp_tertiary} iburst"
            } > /etc/ntp.conf

            log_ok "NTP 配置已写入: /etc/ntp.conf"
            systemctl enable ntpd 2>/dev/null || true
            systemctl restart ntpd 2>/dev/null || true
            log_info "等待 NTPD 同步（5秒）..."
            sleep 5
            sync_ok=true

            echo ""
            log_info "NTP peers 状态:"
            ntpq -p 2>/dev/null | while IFS= read -r line; do
                echo -e "         ${line}"
            done
            ;;

        ntpdate)
            log_info "使用 ntpdate 单次同步..."
            if ntpdate -b "$ntp_primary" 2>/dev/null; then
                sync_ok=true
                log_ok "ntpdate 同步成功 (${ntp_primary})"
            elif ntpdate -b "$ntp_secondary" 2>/dev/null; then
                sync_ok=true
                log_ok "ntpdate 同步成功 (${ntp_secondary})"
            fi
            ;;

        sntp)
            log_info "使用 sntp 同步..."
            if sntp -S "$ntp_primary" 2>/dev/null; then
                sync_ok=true
                log_ok "sntp 同步成功 (${ntp_primary})"
            fi
            ;;

        http)
            log_warn "未检测到NTP工具，使用HTTP方式同步..."
            ;;
    esac

    # ---- 备用HTTP同步 ----
    if [[ "$sync_ok" != "true" ]]; then
        log_warn "NTP同步失败或不可用，尝试HTTP时间同步..."
        local http_date=""
        for url in "https://www.google.com" "https://www.cloudflare.com" "https://www.baidu.com"; do
            http_date=$(curl -sI --max-time 5 "$url" 2>/dev/null | grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //i' | tr -d '\r')
            if [[ -n "$http_date" ]]; then
                if date -s "$http_date" >/dev/null 2>&1; then
                    sync_ok=true
                    log_ok "HTTP时间同步成功 (来源: ${url})"
                    break
                fi
            fi
        done
    fi

    # ---- 写入硬件时钟 ----
    if command -v hwclock &>/dev/null; then
        hwclock --systohc 2>/dev/null || true
        log_info "已同步到硬件时钟"
    fi

    echo ""
    local time_after
    time_after=$(date '+%Y-%m-%d %H:%M:%S')
    log_info "同步后时间: ${GREEN}${time_after}${NC}"

    if [[ "$sync_ok" == "true" ]]; then
        log_ok "时间同步完成！"
    else
        log_error "时间同步失败，请手动检查网络"
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

    echo ""
    if command -v timedatectl &>/dev/null; then
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
    echo -e "  ${CYAN}[后续命令提示]${NC}"
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

    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        echo ""
        log_warn "建议使用 root 权限运行: sudo bash $0"
        echo ""
    fi

    # 四个阶段按顺序执行
    stage_get_info
    stage_set_timezone
    stage_sync_time
    stage_show_result
}

main "$@"
