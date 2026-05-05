#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# 根据公网 IP 归属地自动调整时区并同步时间
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash timesync.sh
# ============================================================

set -euo pipefail

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

# 非交互环境检测与终端命令安全包装
is_interactive_terminal() {
    [[ -t 1 ]] && [[ -n "${TERM:-}" ]]
}

safe_clear() {
    if is_interactive_terminal && command -v clear &>/dev/null; then
        clear || true
    fi
}

safe_tput() {
    if is_interactive_terminal && command -v tput &>/dev/null; then
        tput "$@" 2>/dev/null || true
    fi
}

safe_stty() {
    if [[ -t 0 ]] && command -v stty &>/dev/null; then
        stty "$@" 2>/dev/null || true
    fi
}

prompt_enter_to_continue() {
    if [[ -t 0 ]] && is_interactive_terminal; then
        read -r -p "按 Enter 继续..." _unused || true
    fi
}

# 日志函数
log_info()  { echo -e "  ${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "  ${GREEN}[ OK ]${NC}  $1"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "  ${RED}[FAIL]${NC}  $1"; }

# 从 HTTP 响应头提取 Date（兼容 set -euo pipefail，pipeline 末尾有 || true）
fetch_http_date() {
    local url="$1"
    curl -sI --max-time 5 "$url" 2>/dev/null | \
        grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //i' | tr -d '\r' || true
}

separator() {
    echo -e "${CYAN}================================================================${NC}"
}

#================================================================
# 检测包管理器并安装软件
#================================================================
install_package() {
    local pkg="$1"
    # 部分软件包名与二进制文件名不同（如 chrony→chronyd, ntp→ntpd）
    local binary="${2:-$1}"
    log_info "正在安装 ${pkg}..."

    local ret=0

    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 || ret=$?
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg" >/dev/null 2>&1 || ret=$?
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg" >/dev/null 2>&1 || ret=$?
    elif command -v apk &>/dev/null; then
        apk add --quiet "$pkg" >/dev/null 2>&1 || ret=$?
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --quiet "$pkg" >/dev/null 2>&1 || ret=$?
    else
        log_error "未识别的包管理器，无法安装 ${pkg}"
        return 1
    fi

    if [[ $ret -eq 0 ]] && command -v "$binary" &>/dev/null; then
        log_ok "${pkg} 安装成功"
        return 0
    else
        log_error "${pkg} 安装失败"
        return 1
    fi
}

#================================================================
# 验证 IPv4 地址格式
#================================================================
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
    [[ "$ip" != "0.0.0.0" ]] && \
    [[ "$ip" != "127.0.0.1" ]]
}

#================================================================
# 判断是否使用 systemd
#================================================================
has_systemd() {
    systemctl --version &>/dev/null 2>&1
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

    # 按优先级尝试多个来源
    local ip_sources=(
        "ip.sb"
        "ifconfig.me"
        "icanhazip.com"
        "checkip.amazonaws.com"
    )

    for src in "${ip_sources[@]}"; do
        PUBLIC_IP=$(curl -4 -s --max-time 10 --connect-timeout 5 "$src" 2>/dev/null | tr -d ' \n\r')
        if is_valid_ipv4 "$PUBLIC_IP"; then
            log_ok "公网IPv4: ${GREEN}${PUBLIC_IP}${NC} (来源: ${src})"
            break
        fi
        PUBLIC_IP=""
    done

    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "所有方法均无法获取有效公网IPv4，脚本退出"
        log_info "提示：若机器为 IPv6-only 环境，脚本暂不支持"
        exit 1
    fi

    log_info "正在查询IP归属信息 (ipinfo.io/${PUBLIC_IP})..."
    local raw_json=""
    raw_json=$(curl -s --max-time 15 "https://ipinfo.io/${PUBLIC_IP}" 2>/dev/null)

    if [[ -z "$raw_json" ]]; then
        log_error "无法从 ipinfo.io 获取信息，脚本退出"
        exit 1
    fi

    # 优先用 jq，jq 不存在则先尝试安装
    if command -v jq &>/dev/null; then
        DETECTED_TZ=$(echo "$raw_json" | jq -r '.timezone // empty' 2>/dev/null || echo "")
        COUNTRY=$(echo "$raw_json" | jq -r '.country // empty' 2>/dev/null || echo "")
        CITY=$(echo "$raw_json" | jq -r '.city // empty' 2>/dev/null || echo "")
        REGION=$(echo "$raw_json" | jq -r '.region // empty' 2>/dev/null || echo "")
        ORG=$(echo "$raw_json" | jq -r '.org // empty' 2>/dev/null || echo "")
    else
        if install_package jq 2>/dev/null && command -v jq &>/dev/null; then
            DETECTED_TZ=$(echo "$raw_json" | jq -r '.timezone // empty' 2>/dev/null || echo "")
            COUNTRY=$(echo "$raw_json" | jq -r '.country // empty' 2>/dev/null || echo "")
            CITY=$(echo "$raw_json" | jq -r '.city // empty' 2>/dev/null || echo "")
            REGION=$(echo "$raw_json" | jq -r '.region // empty' 2>/dev/null || echo "")
            ORG=$(echo "$raw_json" | jq -r '.org // empty' 2>/dev/null || echo "")
        else
            # 严格兜底，sed 解析 JSON（兼容所有平台，包括 Alpine BusyBox）
            DETECTED_TZ=$(echo "$raw_json" | sed -n 's/.*"timezone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
            COUNTRY=$(echo "$raw_json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
            CITY=$(echo "$raw_json" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
            REGION=$(echo "$raw_json" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
            ORG=$(echo "$raw_json" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || echo "")
        fi
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

    # 记录旧的链接目标，防止 ln 失败后没有时区
    local old_tz_link
    old_tz_link=$(readlink /etc/localtime 2>/dev/null || echo "")

    rm -f /etc/localtime 2>/dev/null
    if ! ln -s "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null; then
        log_error "无法创建 /etc/localtime 链接（可能为只读文件系统）"
        # 尝试恢复旧链接
        [[ -n "$old_tz_link" ]] && ln -sf "$old_tz_link" /etc/localtime 2>/dev/null; true
        exit 1
    fi
    echo "$tz" > /etc/timezone 2>/dev/null || true

    local verify_tz=""
    verify_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')
    if [[ "$verify_tz" == "$tz" ]]; then
        log_ok "链接方式设置成功: ${GREEN}${tz}${NC}"
    else
        log_error "时区设置验证失败"
        exit 1
    fi
    echo ""
}

#================================================================
# 停止冲突的时间同步服务
#================================================================
stop_conflicting_services() {
    if ! has_systemd; then
        log_info "非 systemd 环境，跳过服务停止步骤"
        return 0
    fi

    # 先关闭 systemd 的 NTP 管理，防止它在后续步骤中干预 chrony 的启停
    timedatectl set-ntp false 2>/dev/null || true

    if systemctl is-active systemd-timesyncd &>/dev/null; then
        log_info "停止 systemd-timesyncd 避免冲突..."
        systemctl stop systemd-timesyncd 2>/dev/null || true
        systemctl disable systemd-timesyncd 2>/dev/null || true
        systemctl mask systemd-timesyncd 2>/dev/null || true
        log_ok "systemd-timesyncd 已停止并禁用"
    fi

    if systemctl is-active ntpd &>/dev/null 2>&1; then
        log_info "停止 ntpd..."
        systemctl stop ntpd 2>/dev/null || true
        systemctl disable ntpd 2>/dev/null || true
    fi

    # 停止所有可能的 chrony 服务单元名（chrony 和 chronyd 二选一或两者都有）
    for _u in chrony chronyd; do
        if systemctl is-active "$_u" &>/dev/null 2>&1 || systemctl is-enabled "$_u" &>/dev/null 2>&1; then
            log_info "停止 ${_u}..."
            systemctl stop "$_u" 2>/dev/null || true
        fi
    done

    # 强制结束所有残留 chronyd 进程
    if pgrep -x chronyd &>/dev/null; then
        log_info "清理残留 chronyd 进程..."
        pkill -x chronyd 2>/dev/null || true
        sleep 1
    fi

    # 清理旧的 PID / socket 文件，防止二次运行时 daemon 启动失败
    rm -f /run/chrony/chronyd.pid /var/run/chrony/chronyd.pid \
          /run/chronyd.pid /var/run/chronyd.pid \
          /run/chrony/chronyd.sock /var/run/chrony/chronyd.sock 2>/dev/null || true
}

#================================================================
# 获取 chrony 配置路径（修复目录不存在时的 bug）
#================================================================
get_chrony_conf_path() {
    if [[ -f /etc/chrony/chrony.conf ]]; then
        echo "/etc/chrony/chrony.conf"
    elif [[ -f /etc/chrony.conf ]]; then
        echo "/etc/chrony.conf"
    elif [[ -d /etc/chrony ]]; then
        echo "/etc/chrony/chrony.conf"
    else
        mkdir -p /etc/chrony 2>/dev/null || true
        echo "/etc/chrony/chrony.conf"
    fi
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

    log_info "根据时区选择最优NTP服务器..."

    local ntp_primary="" ntp_secondary="" ntp_tertiary=""

    case "$tz" in
        Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi)
            ntp_primary="ntp.aliyun.com"; ntp_secondary="ntp.tencent.com"; ntp_tertiary="cn.pool.ntp.org" ;;
        Asia/Hong_Kong)
            ntp_primary="hk.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Tokyo)
            ntp_primary="jp.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Seoul)
            ntp_primary="kr.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Singapore)
            ntp_primary="sg.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Taipei)
            ntp_primary="tw.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Kolkata)
            ntp_primary="in.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/Bangkok|Asia/Ho_Chi_Minh|Asia/Jakarta|Asia/Manila)
            ntp_primary="asia.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Asia/*)
            ntp_primary="asia.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Europe/London)
            ntp_primary="uk.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Europe/Berlin|Europe/Paris|Europe/Amsterdam|Europe/Madrid|Europe/Rome)
            ntp_primary="de.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Europe/Moscow)
            ntp_primary="ru.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Europe/*)
            ntp_primary="europe.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        America/New_York|America/Chicago|America/Denver|America/Los_Angeles|America/Phoenix)
            ntp_primary="us.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        America/Toronto|America/Vancouver)
            ntp_primary="ca.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        America/Sao_Paulo)
            ntp_primary="br.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        America/*)
            ntp_primary="north-america.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Australia/*|Pacific/Auckland)
            ntp_primary="oceania.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        Africa/*)
            ntp_primary="africa.pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
        *)
            ntp_primary="pool.ntp.org"; ntp_secondary="time.google.com"; ntp_tertiary="time.cloudflare.com" ;;
    esac

    log_ok "主NTP: ${GREEN}${ntp_primary}${NC}"
    log_ok "备NTP: ${GREEN}${ntp_secondary}${NC}"
    log_ok "三NTP: ${GREEN}${ntp_tertiary}${NC}"
    echo ""

    # ---- 检测 / 安装同步工具 ----
    local sync_tool=""
    if command -v chronyd &>/dev/null; then
        sync_tool="chrony"
    elif command -v ntpdate &>/dev/null; then
        sync_tool="ntpdate"
    elif command -v ntpd &>/dev/null; then
        sync_tool="ntpd"
    else
        log_warn "未检测到NTP工具，正在自动安装..."
        echo ""
        if install_package "chrony" "chronyd"; then
            sync_tool="chrony"
        elif install_package "ntpdate"; then
            sync_tool="ntpdate"
        elif install_package "ntp" "ntpd"; then
            sync_tool="ntpd"
        else
            sync_tool="http"
            log_warn "所有NTP工具安装失败，将使用HTTP方式同步"
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
            stop_conflicting_services

            local chrony_conf
            chrony_conf=$(get_chrony_conf_path)

            # 备份旧配置（使用 time_before 避免覆盖）
            if [[ -f "$chrony_conf" ]]; then
                cp "$chrony_conf" "${chrony_conf}.bak.${time_before// /_}" 2>/dev/null || true
            fi

            cat > "$chrony_conf" <<EOF
# Auto-generated by timesync
server ${ntp_primary} iburst
server ${ntp_secondary} iburst
server ${ntp_tertiary} iburst

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF
            log_ok "配置已写入: ${chrony_conf}"

            # Ensure necessary directories exist for chrony
            mkdir -p /var/lib/chrony /var/run/chrony /var/log/chrony 2>/dev/null || true

            # Determine the chrony user (Debian/Ubuntu use 'chrony', others use '_chrony')
            local _chrony_user=""
            for _cu in _chrony chrony; do
                if id -u "$_cu" &>/dev/null; then
                    _chrony_user="$_cu"
                    break
                fi
            done

            if [[ -n "$_chrony_user" ]]; then
                chown "${_chrony_user}:${_chrony_user}" /var/lib/chrony /var/run/chrony /var/log/chrony 2>/dev/null || true
                chmod 0750 /var/lib/chrony /var/run/chrony /var/log/chrony 2>/dev/null || true
            else
                chmod 0755 /var/lib/chrony /var/run/chrony /var/log/chrony 2>/dev/null || true
            fi

            # Always remove stale PID / socket files before starting (covers all user cases)
            rm -f /run/chrony/chronyd.pid /var/run/chrony/chronyd.pid \
                  /run/chronyd.pid /var/run/chronyd.pid \
                  /run/chrony/chronyd.sock /var/run/chrony/chronyd.sock 2>/dev/null || true

            if has_systemd; then
                # Detect which unit name is available on this system (chrony vs chronyd)
                local _svc=""
                for _u in chrony chronyd; do
                    if systemctl list-unit-files "${_u}.service" 2>/dev/null | grep -q "${_u}.service"; then
                        _svc="$_u"
                        break
                    fi
                done
                # Fallback: try enabling each to detect the real unit
                if [[ -z "$_svc" ]]; then
                    if systemctl enable chrony >/dev/null 2>&1; then
                        _svc=chrony
                    elif systemctl enable chronyd >/dev/null 2>&1; then
                        _svc=chronyd
                    else
                        _svc=chrony  # last resort default
                    fi
                fi

                systemctl enable "$_svc" 2>/dev/null || true
                systemctl restart "$_svc" 2>/dev/null || systemctl start "$_svc" 2>/dev/null || true

                # Give it a moment to come up and retry starting if it immediately exited
                sleep 2

                # If the selected unit isn't active, try the other common name
                if ! systemctl is-active --quiet "${_svc}"; then
                    local _alt_svc
                    [[ "${_svc}" == "chrony" ]] && _alt_svc="chronyd" || _alt_svc="chrony"
                    systemctl restart "$_alt_svc" 2>/dev/null || systemctl start "$_alt_svc" 2>/dev/null || true
                    if systemctl is-active --quiet "$_alt_svc"; then
                        _svc="$_alt_svc"
                    fi
                fi

                # Wait up to 10s for the unit to be active (some distros start and then early-exit)
                local _wait=0
                while ! systemctl is-active --quiet "${_svc}" && [[ "$_wait" -lt 10 ]]; do
                    sleep 1
                    _wait=$(( _wait + 1 ))
                done

                # If chrony still isn't active, capture logs when possible to help debugging
                if ! systemctl is-active --quiet "${_svc}"; then
                    if command -v journalctl &>/dev/null; then
                        log_warn "chrony 服务未能成功启动，最近日志：\n$(journalctl -u ${_svc} -n 200 --no-pager 2>/dev/null | sed 's/^/  /')"
                    else
                        log_warn "chrony 服务未能成功启动，无法读取 journalctl 日志。请手动检查服务状态。"
                    fi
                fi
            else
                # Non-systemd environments: attempt to start chronyd directly
                if command -v chronyd &>/dev/null; then
                    chronyd 2>/dev/null &
                fi
            fi

            log_info "等待 Chrony 同步（6秒）..."
            sleep 6

            # Wait for chronyc to be responsive before makestep
            local _tries=0
            while ! chronyc tracking >/dev/null 2>&1 && [[ "$_tries" -lt 5 ]]; do
                sleep 1
                _tries=$(( _tries + 1 ))
            done

            if chronyc -a makestep >/dev/null 2>&1; then
                sync_ok=true
                log_ok "Chrony makestep 执行成功"
            else
                log_warn "chronyc makestep 返回异常"
            fi

            echo ""
            log_info "Chrony 同步源:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            chronyc sources 2>/dev/null | sed 's/^/  /'
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"

            echo ""
            log_info "Chrony tracking:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            chronyc tracking 2>/dev/null | sed 's/^/  /'
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ;;

        ntpdate)
            log_info "使用 ntpdate 单次同步..."
            stop_conflicting_services

            for srv in "$ntp_primary" "$ntp_secondary" "$ntp_tertiary"; do
                log_info "尝试 ${srv}..."
                local output
                if output=$(ntpdate -b "$srv" 2>&1); then
                    sync_ok=true
                    log_ok "ntpdate 同步成功 (${srv})"
                    echo "         ${output}"
                    break
                else
                    log_warn "${srv} 失败: ${output}"
                fi
            done
            ;;

        ntpd)
            log_info "配置 NTPD..."
            stop_conflicting_services

            [[ -f /etc/ntp.conf ]] && cp /etc/ntp.conf /etc/ntp.conf.bak 2>/dev/null; true

            cat > /etc/ntp.conf <<EOF
# Auto-generated by timesync
driftfile /var/lib/ntp/drift
restrict default kod nomodify notrap nopeer noquery
restrict 127.0.0.1

server ${ntp_primary} iburst prefer
server ${ntp_secondary} iburst
server ${ntp_tertiary} iburst
EOF
            log_ok "配置已写入: /etc/ntp.conf"

            if has_systemd; then
                systemctl enable ntpd 2>/dev/null || true
                systemctl start ntpd 2>/dev/null || true
            fi
            log_info "等待 NTPD 同步（6秒）..."
            sleep 6
            sync_ok=true

            echo ""
            log_info "NTP peers:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ntpq -p 2>/dev/null | sed 's/^/  /'
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ;;

        http)
            log_warn "使用HTTP方式获取时间（精度较低）..."
            for url in "https://www.google.com" "https://www.cloudflare.com" "https://www.baidu.com"; do
                local http_date
                http_date=$(fetch_http_date "$url")
                if [[ -n "$http_date" ]]; then
                    log_info "获取到HTTP时间: ${http_date}"
                    if date -s "$http_date" >/dev/null 2>&1; then
                        sync_ok=true
                        log_ok "HTTP时间同步成功 (${url})"
                        break
                    fi
                fi
            done
            ;;
    esac

    # ---- HTTP 兜底 ----
    if [[ "$sync_ok" != "true" ]] && [[ "$sync_tool" != "http" ]]; then
        echo ""
        log_warn "NTP同步未成功，尝试HTTP方式兜底..."
        for url in "https://www.google.com" "https://www.cloudflare.com" "https://www.baidu.com"; do
            local http_date
            http_date=$(fetch_http_date "$url")
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
        timedatectl status 2>/dev/null | sed 's/^/     /'
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
    safe_clear
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

    # 检查核心依赖
    if ! command -v curl &>/dev/null; then
        log_error "未找到 curl，脚本需要 curl 访问 IP 和 NTP 服务"
        log_info "尝试安装 curl..."
        install_package curl || {
            log_error "无法安装 curl，请手动安装后重新运行"
            exit 1
        }
    fi

    stage_get_info
    stage_set_timezone
    stage_sync_time
    stage_show_result
}

main "$@"
