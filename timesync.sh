#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# 根据公网 IP 归属地自动调整时区并同步时间
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash timesync.sh [--egress auto|IFACE|IP] [--list] [--dry-run]
# ============================================================

set -euo pipefail

VERSION="1.3.0"

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

# 出口（egress）相关
EGRESS_IFACE=""          # 用于探测公网 IP / NTP 的网卡名（空=跟随系统路由）
EGRESS_IP=""             # 该网卡的本地 IPv4（仅用于展示）
EGRESS_SOURCE=""         # auto | saved | cli | interactive
FORCE_TZ=""              # --tz 手动指定时区，跳过网络探测
CONFIG_FILE="${TIMESYNC_CONFIG:-/etc/timesync.conf}"
LIST_ONLY=false
DRY_RUN=false
ASSUME_YES=false

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

separator() {
    echo -e "${CYAN}================================================================${NC}"
}

usage() {
    cat <<EOF
timesync v${VERSION} — VPS 时区与时间自动校准

用法:
  bash timesync.sh [选项]

选项:
  --egress auto        自动选择出口（默认：优先物理网卡，避开 TUN）
  --egress <网卡名>    指定出口网卡，例如 --egress eth0
  --egress <IP>        指定出口源 IP，脚本自动反查所属网卡
  --tz <时区>          手动指定时区（如 Asia/Shanghai），完全跳过网络探测
  --list               只列出所有网卡及其公网出口，不做任何修改
  --dry-run            只打印将要写入的配置，不修改系统
  --yes                非交互模式，全部使用推荐值
  -h, --help           显示本帮助

说明:
  开启 TUN / 透明代理后，系统默认路由会指向 tun0，脚本探测到的公网 IP
  是落地节点，时区会被带偏。指定 --egress eth0 后，探测请求与 chrony 的
  NTP 查询都会绑定到物理网卡（SO_BINDTODEVICE），从而拿到本机真实归属地。

  选择结果会保存到 ${CONFIG_FILE}，下次运行自动沿用；用 --egress auto 可忽略。
EOF
}

#================================================================
# 出口网卡识别
#================================================================
is_tunnel_iface() {
    case "$1" in
        tun*|tap*|utun*|wg*|awg*|singbox*|sing-tun*|mihomo*|clash*|meta*|Meta*|tailscale*|nebula*|nf*|xray*|hysteria*|hy*|proton*|zt*)
            return 0 ;;
    esac
    return 1
}

is_container_iface() {
    case "$1" in
        docker*|br-*|veth*|virbr*|cni*|flannel*|kube*|podman*|lxcbr*|lxdbr*)
            return 0 ;;
    esac
    return 1
}

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    return 1
}

# 输出 "网卡<TAB>本地IPv4"，跳过 lo / 无地址 / 链路本地
collect_ifaces() {
    ip -4 -o addr show up 2>/dev/null | awk '
        {
            iface=$2; ip="";
            for (i=1; i<=NF; i++) if ($i=="inet") ip=$(i+1);
            if (iface=="lo" || ip=="") next;
            sub(/\/.*/, "", ip);
            if (ip ~ /^127\./ || ip ~ /^169\.254\./) next;
            print iface "\t" ip;
        }'
}

default_iface() {
    ip -4 route show default 0.0.0.0/0 2>/dev/null | \
        awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

iface_local_ip() {
    ip -4 -o addr show dev "$1" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="inet") {print $(i+1); exit}}' | cut -d/ -f1
}

iface_of_ip() {
    ip -4 -o addr show 2>/dev/null | awk -v want="$1" '
        {
            iface=$2; ip="";
            for (i=1; i<=NF; i++) if ($i=="inet") ip=$(i+1);
            sub(/\/.*/, "", ip);
            if (ip==want) {print iface; exit}
        }'
}

# 通过指定网卡做 DoH 解析：不依赖系统 DNS，避免 TUN 的 fake-ip / DNS 劫持
doh_resolve_via() {
    local iface="$1" host="$2" out="" ip=""
    out=$(curl --interface "$iface" -4 -s --max-time 6 -H 'accept: application/dns-json' \
        "https://1.1.1.1/dns-query?name=${host}&type=A" 2>/dev/null || true)
    if command -v jq &>/dev/null; then
        ip=$(printf '%s' "$out" | jq -r '[.Answer[]? | select(.type==1) | .data][0] // empty' 2>/dev/null || true)
    fi
    if ! is_valid_ipv4 "$ip"; then
        ip=$(printf '%s' "$out" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*1[^}]*"data"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1 || true)
    fi
    if ! is_valid_ipv4 "$ip"; then
        # 阿里 DoH 兜底（同样用 IP 直连，不依赖系统 DNS）
        out=$(curl --interface "$iface" -4 -s --max-time 6 --resolve dns.alidns.com:443:223.5.5.5 \
            "https://dns.alidns.com/resolve?name=${host}&type=1" 2>/dev/null || true)
        ip=$(printf '%s' "$out" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1 || true)
    fi
    if is_valid_ipv4 "$ip"; then
        printf '%s' "$ip"
    fi
}

# 绑定网卡 + 自行解析 DNS 的 curl（URL 必须是最后一个参数）
curl_via_iface() {
    local iface="$1"; shift
    local -a args=("$@")
    local url="${args[${#args[@]}-1]}"
    local host="" ip=""
    host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#')
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        curl --interface "$iface" "${args[@]}"
        return
    fi
    ip=$(doh_resolve_via "$iface" "$host" || true)
    if [[ -n "$ip" ]]; then
        curl --interface "$iface" --resolve "${host}:443:${ip}" --resolve "${host}:80:${ip}" "${args[@]}"
    else
        curl --interface "$iface" "${args[@]}"
    fi
}

# 通过指定网卡探测公网 IPv4（--interface 传网卡名时 curl 使用 SO_BINDTODEVICE）
probe_public_ip() {
    local iface="$1" out=""
    out=$(curl_via_iface "$iface" -4 -s --max-time 6 --connect-timeout 4 https://ip.sb 2>/dev/null | tr -d ' \n\r' || true)
    if ! is_valid_ipv4 "$out"; then
        out=$(curl_via_iface "$iface" -4 -s --max-time 6 --connect-timeout 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1 | tr -d ' \r' || true)
    fi
    if is_valid_ipv4 "$out"; then
        printf '%s' "$out"
    fi
}

load_saved_egress() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local v
    v=$(sed -n 's/^EGRESS_IFACE=//p' "$CONFIG_FILE" 2>/dev/null | head -1 | tr -d '"'"'"' \r' || true)
    if [[ -n "$v" ]] && ip link show "$v" &>/dev/null; then
        EGRESS_IFACE="$v"
        EGRESS_IP=$(iface_local_ip "$v")
        EGRESS_SOURCE="saved"
    fi
}

save_egress() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    [[ -n "$EGRESS_IFACE" ]] || return 0
    {
        echo "# timesync 出口配置（由 timesync v${VERSION} 生成）"
        echo "# 删除本文件或使用 --egress auto 可恢复自动选择"
        echo "EGRESS_IFACE=${EGRESS_IFACE}"
    } > "$CONFIG_FILE" 2>/dev/null || log_warn "无法写入 ${CONFIG_FILE}，本次选择不会保存"
}

#================================================================
# 阶段零：选择探测出口（绕过 TUN）
#================================================================
stage_select_egress() {
    separator
    echo -e "${CYAN}  [阶段零] 选择探测出口${NC}"
    separator
    echo ""

    local def_iface
    def_iface=$(default_iface)

    # 收集候选
    local -a names=() ips=() pubs=() kinds=()
    local iface ip pub kind
    while IFS=$'\t' read -r iface ip; do
        [[ -z "$iface" ]] && continue
        kind="直连"
        if is_tunnel_iface "$iface"; then
            kind="隧道"
        elif is_container_iface "$iface"; then
            kind="容器"
        elif is_private_ipv4 "$ip"; then
            kind="私网"
        fi
        pub=""
        # 容器网桥不探测；私网网卡仍要探测（NAT VPS 的内网 IP 也能出公网）
        if [[ "$kind" != "容器" ]]; then
            pub=$(probe_public_ip "$iface")
        fi
        names+=("$iface"); ips+=("$ip"); pubs+=("$pub"); kinds+=("$kind")
    done < <(collect_ifaces)

    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "未找到可用网卡，将跟随系统默认路由"
        EGRESS_IFACE=""
        echo ""
        return 0
    fi

    # 推荐：默认路由网卡（非隧道）> 第一个有公网出口的非隧道网卡 > 默认路由网卡
    local recommended="" i
    if [[ -n "$def_iface" ]] && ! is_tunnel_iface "$def_iface"; then
        recommended="$def_iface"
    fi
    if [[ -z "$recommended" ]]; then
        for i in "${!names[@]}"; do
            if [[ "${kinds[$i]}" != "隧道" && "${kinds[$i]}" != "容器" && -n "${pubs[$i]}" ]]; then
                recommended="${names[$i]}"
                break
            fi
        done
    fi
    [[ -z "$recommended" ]] && recommended="${names[0]}"

    # 展示
    echo -e "  ${YELLOW}可用出口：${NC}"
    for i in "${!names[@]}"; do
        local mark="  "
        [[ "${names[$i]}" == "$recommended" ]] && mark="* "
        local pubtxt="${pubs[$i]:-无公网出口}"
        local tag="[${kinds[$i]}]"
        [[ "${names[$i]}" == "$def_iface" ]] && tag="${tag}[默认路由]"
        printf "  %s%d) %-10s %-16s → %-16s %s\n" "$mark" "$((i+1))" "${names[$i]}" "${ips[$i]}" "$pubtxt" "$tag"
    done
    echo ""

    if [[ -n "$def_iface" ]] && is_tunnel_iface "$def_iface"; then
        log_warn "检测到默认路由指向隧道网卡 ${def_iface}，直接探测会拿到落地节点时区"
    fi

    # 决定选择
    local choice=""
    if [[ "$EGRESS_SOURCE" == "cli" ]]; then
        choice="$EGRESS_IFACE"
        log_info "使用命令行指定出口: ${GREEN}${choice}${NC}"
    elif [[ "$EGRESS_SOURCE" == "saved" ]]; then
        choice="$EGRESS_IFACE"
        log_info "沿用上次保存的出口: ${GREEN}${choice}${NC}（--egress auto 可重新选择）"
    elif [[ "$ASSUME_YES" == "true" ]] || ! is_interactive_terminal || [[ ! -t 0 ]]; then
        choice="$recommended"
        log_info "非交互模式，使用推荐出口: ${GREEN}${choice}${NC}"
    else
        local ans=""
        read -r -p "  选择出口 [回车=${recommended}，输入序号/网卡名，q 退出]: " ans || true
        if [[ "$ans" == "q" || "$ans" == "Q" ]]; then
            echo ""
            log_info "已取消"
            exit 0
        fi
        if [[ -z "$ans" ]]; then
            choice="$recommended"
        elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#names[@]} )); then
            choice="${names[$((ans-1))]}"
        elif ip link show "$ans" &>/dev/null; then
            choice="$ans"
        else
            log_warn "无效输入，使用推荐出口: ${recommended}"
            choice="$recommended"
        fi
    fi

    EGRESS_IFACE="$choice"
    EGRESS_IP=$(iface_local_ip "$EGRESS_IFACE")

    if is_tunnel_iface "$EGRESS_IFACE"; then
        log_warn "已选择隧道网卡 ${EGRESS_IFACE}：时区将跟随落地节点，这是你主动选择的"
    else
        log_ok "探测出口: ${GREEN}${EGRESS_IFACE}${NC} (${EGRESS_IP})，已绕过 TUN"
    fi

    save_egress
    echo ""
}

# 统一出口的 curl 包装：绑定网卡后，请求不会走 TUN
curl_egress() {
    if [[ -n "$EGRESS_IFACE" ]]; then
        curl_via_iface "$EGRESS_IFACE" "$@"
    else
        curl "$@"
    fi
}

# 从 HTTP 响应头提取 Date（兼容 set -euo pipefail，pipeline 末尾有 || true）
fetch_http_date() {
    local url="$1"
    curl_egress -sI --max-time 5 "$url" 2>/dev/null | \
        grep -i "^date:" | head -1 | sed 's/^[Dd]ate: //i' | tr -d '\r' || true
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
        "https://ip.sb"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://checkip.amazonaws.com"
    )

    for src in "${ip_sources[@]}"; do
        PUBLIC_IP=$(curl_egress -4 -s --max-time 10 --connect-timeout 5 "$src" 2>/dev/null | tr -d ' \n\r' || true)
        if is_valid_ipv4 "$PUBLIC_IP"; then
            log_ok "公网IPv4: ${GREEN}${PUBLIC_IP}${NC} (来源: ${src})"
            break
        fi
        PUBLIC_IP=""
    done

    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "所有方法均无法获取有效公网IPv4，脚本退出"
        if [[ -n "$EGRESS_IFACE" ]]; then
            log_info "已绑定出口 ${EGRESS_IFACE} 仍失败，常见原因："
            log_info "  1) TUN 把物理网卡的默认路由从主路由表移除了（strict_route）"
            log_info "  2) 该网卡本身没有公网出口"
            log_info "可改用: bash $0 --egress tun0   （跟随落地时区）"
            log_info "或:     bash $0 --tz Asia/Shanghai   （手动指定，不联网）"
        else
            log_info "提示：若机器为 IPv6-only 环境，脚本暂不支持"
        fi
        exit 1
    fi

    log_info "正在查询IP归属信息 (ipinfo.io/${PUBLIC_IP})..."
    local raw_json=""
    raw_json=$(curl_egress -s --max-time 15 "https://ipinfo.io/${PUBLIC_IP}" 2>/dev/null || true)

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
        current_tz=$(cat /etc/timezone 2>/dev/null || true)
    fi
    if [[ -z "$current_tz" ]]; then
        current_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||' || true)
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

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] 将执行: timedatectl set-timezone ${tz}"
        echo ""
        return 0
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
    verify_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||' || true)
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

# chrony 主版本号（bindacqdevice 需要 >= 4.0）
chrony_major_version() {
    local v=""
    v=$(chronyd -v 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    [[ -z "$v" ]] && return 1
    echo "${v%%.*}"
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

    # TUN 环境下系统 DNS 可能被劫持（fake-ip），chrony 解析域名会失败
    # 这里用 DoH 走物理网卡把 NTP 域名解析成 IP 再写进配置
    local ntp_primary_host="$ntp_primary" ntp_secondary_host="$ntp_secondary" ntp_tertiary_host="$ntp_tertiary"
    if [[ -n "$EGRESS_IFACE" ]]; then
        local rip=""
        rip=$(doh_resolve_via "$EGRESS_IFACE" "$ntp_primary_host" || true)
        [[ -n "$rip" ]] && ntp_primary="$rip"
        rip=$(doh_resolve_via "$EGRESS_IFACE" "$ntp_secondary_host" || true)
        [[ -n "$rip" ]] && ntp_secondary="$rip"
        rip=$(doh_resolve_via "$EGRESS_IFACE" "$ntp_tertiary_host" || true)
        [[ -n "$rip" ]] && ntp_tertiary="$rip"
    fi

    log_ok "主NTP: ${GREEN}${ntp_primary_host}${NC} -> ${GREEN}${ntp_primary}${NC}"
    log_ok "备NTP: ${GREEN}${ntp_secondary_host}${NC} -> ${GREEN}${ntp_secondary}${NC}"
    log_ok "三NTP: ${GREEN}${ntp_tertiary_host}${NC} -> ${GREEN}${ntp_tertiary}${NC}"
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

            # 出口锁定：NTP 客户端 socket 绑定物理网卡，绕过 TUN
            local bind_line=""
            if [[ -n "$EGRESS_IFACE" ]]; then
                local cmaj=""
                cmaj=$(chrony_major_version || true)
                if [[ -n "$cmaj" ]] && (( cmaj >= 4 )); then
                    bind_line="bindacqdevice ${EGRESS_IFACE}"
                    log_ok "NTP 出口锁定: ${GREEN}${EGRESS_IFACE}${NC} (bindacqdevice)"
                else
                    log_warn "chrony 版本 < 4.0，不支持 bindacqdevice，NTP 查询仍可能走 TUN"
                    log_info "建议升级 chrony 后重跑本脚本"
                fi
            fi

            # 备份旧配置（使用 time_before 避免覆盖）
            if [[ -f "$chrony_conf" ]]; then
                cp "$chrony_conf" "${chrony_conf}.bak.${time_before// /_}" 2>/dev/null || true
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                echo ""
                log_info "[dry-run] 将写入 ${chrony_conf}:"
                echo "  -----------------------------------------------------------"
                echo "  # Auto-generated by timesync v${VERSION}"
                echo "  # ${ntp_primary_host}"
                echo "  server ${ntp_primary} iburst"
                echo "  # ${ntp_secondary_host}"
                echo "  server ${ntp_secondary} iburst"
                echo "  # ${ntp_tertiary_host}"
                echo "  server ${ntp_tertiary} iburst"
                echo "  driftfile /var/lib/chrony/chrony.drift"
                echo "  makestep 1.0 3"
                echo "  rtcsync"
                [[ -n "$bind_line" ]] && echo "  ${bind_line}"
                echo "  -----------------------------------------------------------"
                echo ""
                return 0
            fi

            cat > "$chrony_conf" <<EOF
# Auto-generated by timesync v${VERSION}
# ${ntp_primary_host}
server ${ntp_primary} iburst
# ${ntp_secondary_host}
server ${ntp_secondary} iburst
# ${ntp_tertiary_host}
server ${ntp_tertiary} iburst

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF
            if [[ -n "$bind_line" ]]; then
                echo "" >> "$chrony_conf"
                echo "# 出口锁定：NTP 查询强制走物理网卡，避免被 TUN 接管" >> "$chrony_conf"
                echo "${bind_line}" >> "$chrony_conf"
            fi
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
            chronyc sources 2>/dev/null | sed 's/^/  /' || true
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"

            echo ""
            log_info "Chrony tracking:"
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            chronyc tracking 2>/dev/null | sed 's/^/  /' || true
            echo -e "  ${CYAN}-----------------------------------------------------------${NC}"
            ;;

        ntpdate)
            log_info "使用 ntpdate 单次同步..."
            stop_conflicting_services

            if [[ -n "$EGRESS_IFACE" ]]; then
                log_warn "ntpdate 不支持绑定出口网卡，NTP 请求可能仍走 TUN"
                log_info "如需锁定出口，请安装 chrony（>= 4.0）后重跑"
            fi

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

            if [[ -n "$EGRESS_IFACE" ]]; then
                log_warn "ntpd 不支持按网卡锁定出口，NTP 请求可能仍走 TUN"
                log_info "如需锁定出口，请安装 chrony（>= 4.0）后重跑"
            fi

            [[ -f /etc/ntp.conf ]] && cp /etc/ntp.conf /etc/ntp.conf.bak 2>/dev/null; true

            cat > /etc/ntp.conf <<EOF
# Auto-generated by timesync v${VERSION}
driftfile /var/lib/ntp/drift
restrict default kod nomodify notrap nopeer noquery
restrict 127.0.0.1

# ${ntp_primary_host}
server ${ntp_primary} iburst prefer
# ${ntp_secondary_host}
server ${ntp_secondary} iburst
# ${ntp_tertiary_host}
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
            ntpq -p 2>/dev/null | sed 's/^/  /' || true
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
    echo -e "  ${YELLOW}[出口信息]${NC}"
    if [[ -n "$EGRESS_IFACE" ]]; then
        echo -e "     探测网卡:    ${GREEN}${EGRESS_IFACE}${NC} (${EGRESS_IP})"
        if is_tunnel_iface "$EGRESS_IFACE"; then
            echo -e "     出口类型:    ${YELLOW}隧道（时区跟随落地节点）${NC}"
        else
            echo -e "     出口类型:    ${GREEN}物理网卡直连（已绕过 TUN）${NC}"
        fi
    else
        echo -e "     探测网卡:    ${YELLOW}跟随系统默认路由${NC}"
    fi

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
        timedatectl status 2>/dev/null | sed 's/^/     /' || true
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
    echo "     切换出口:     bash $0 --egress eth0"
    echo ""
}

#================================================================
# 参数解析
#================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --egress)
                [[ $# -ge 2 ]] || { log_error "--egress 需要一个参数"; exit 1; }
                local val="$2"
                if [[ "$val" == "auto" ]]; then
                    EGRESS_IFACE=""
                    EGRESS_SOURCE=""
                elif ip link show "$val" &>/dev/null; then
                    EGRESS_IFACE="$val"
                    EGRESS_SOURCE="cli"
                elif is_valid_ipv4 "$val"; then
                    local dev
                    dev=$(iface_of_ip "$val")
                    if [[ -z "$dev" ]]; then
                        log_error "IP ${val} 不属于任何本机网卡"
                        exit 1
                    fi
                    EGRESS_IFACE="$dev"
                    EGRESS_SOURCE="cli"
                else
                    log_error "无效的出口: ${val}（应为 auto / 网卡名 / 本机 IP）"
                    exit 1
                fi
                shift 2
                ;;
            --list)
                LIST_ONLY=true
                shift
                ;;
            --tz)
                [[ $# -ge 2 ]] || { log_error "--tz 需要一个时区参数"; exit 1; }
                FORCE_TZ="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --yes|-y)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done
}

#================================================================
# 主函数
#================================================================
main() {
    parse_args "$@"

    safe_clear
    echo ""
    separator
    echo -e "${CYAN}          VPS 时区和时间自动校准脚本${NC}"
    echo -e "${CYAN}      Auto Timezone & Time Calibration  v${VERSION}${NC}"
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

    if ! command -v ip &>/dev/null; then
        log_error "未找到 ip 命令（iproute2），无法识别出口网卡"
        log_info "尝试安装 iproute2..."
        install_package iproute2 ip || true
    fi

    # 未显式指定时，沿用上次保存的出口
    if [[ -z "$EGRESS_SOURCE" ]]; then
        load_saved_egress
    fi

    if [[ "$LIST_ONLY" == "true" ]]; then
        stage_select_egress
        log_info "仅列出出口，未做任何修改"
        exit 0
    fi

    # 手动指定时区：完全跳过网络探测，适合 TUN 环境或探测被墙
    if [[ -n "$FORCE_TZ" ]]; then
        if [[ ! -f "/usr/share/zoneinfo/${FORCE_TZ}" ]]; then
            log_error "时区不存在: ${FORCE_TZ}"
            log_info "可用时区: timedatectl list-timezones | grep -i shanghai"
            exit 1
        fi
        DETECTED_TZ="$FORCE_TZ"
        echo ""
        log_info "手动指定时区: ${GREEN}${DETECTED_TZ}${NC}（跳过网络探测）"
        stage_set_timezone
        stage_sync_time
        stage_show_result
        exit 0
    fi

    stage_select_egress
    stage_get_info
    stage_set_timezone
    stage_sync_time
    stage_show_result
}

main "$@"