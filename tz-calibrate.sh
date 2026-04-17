#!/bin/bash

# ============================================================
# VPS 时区和时间自动校准脚本
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash tz-calibrate.sh
# ============================================================
#

set -e

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# 检测root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS="centos"
    elif [[ -f /etc/alpine-release ]]; then
        OS="alpine"
    elif [[ -f /etc/arch-release ]]; then
        OS="arch"
    else
        OS="unknown"
    fi
    log_info "操作系统: ${OS}"
}

# 获取公网IP
get_public_ip() {
    log_step "获取公网IPv4地址..."
    
    for api in "ip.sb" "ifconfig.me" "api.ipify.org"; do
        PUBLIC_IP=$(curl -4 -s --max-time 8 "https://${api}" 2>/dev/null)
        if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_success "公网IP: ${PUBLIC_IP} (来源: ${api})"
            return 0
        fi
    done
    
    log_error "无法获取公网IP"
    exit 1
}

# 查询时区
get_timezone() {
    log_step "查询IP所在时区..."
    
    # 方法1: ipinfo.io
    local response=$(curl -4 -s --max-time 15 "https://ipinfo.io/${PUBLIC_IP}/json")
    if echo "$response" | grep -q "timezone"; then
        TIMEZONE=$(echo "$response" | grep -o '"timezone": *"[^"]*"' | cut -d'"' -f4)
        COUNTRY=$(echo "$response" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)
        CITY=$(echo "$response" | grep -o '"city": *"[^"]*"' | cut -d'"' -f4)
        log_success "时区: ${TIMEZONE} (${COUNTRY}/${CITY})"
        return 0
    fi
    
    # 方法2: ip-api.com
    response=$(curl -4 -s --max-time 15 "http://ip-api.com/json/${PUBLIC_IP}?fields=timezone,country,city")
    if echo "$response" | grep -q "timezone"; then
        TIMEZONE=$(echo "$response" | grep -o '"timezone":"[^"]*"' | cut -d'"' -f4)
        COUNTRY=$(echo "$response" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        CITY=$(echo "$response" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        log_success "时区: ${TIMEZONE} (${COUNTRY}/${CITY})"
        return 0
    fi
    
    # 方法3: worldtimeapi
    response=$(curl -4 -s --max-time 15 "http://worldtimeapi.org/api/ip/${PUBLIC_IP}.json")
    if echo "$response" | grep -q "timezone"; then
        TIMEZONE=$(echo "$response" | grep -o '"timezone":"[^"]*"' | cut -d'"' -f4)
        log_success "时区: ${TIMEZONE}"
        return 0
    fi
    
    log_warning "无法查询时区，使用默认 Asia/Shanghai"
    TIMEZONE="Asia/Shanghai"
}

# 设置时区
set_timezone() {
    log_step "设置系统时区: ${TIMEZONE}..."
    
    if [[ -f /usr/share/zoneinfo/${TIMEZONE} ]]; then
        case "${OS}" in
            debian|centos|arch)
                timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || \
                ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
                ;;
            alpine)
                ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
                echo "${TIMEZONE}" > /etc/timezone
                ;;
        esac
        log_success "时区设置完成"
    else
        log_error "时区文件不存在: ${TIMEZONE}"
        exit 1
    fi
}

# 安装 chrony
install_chrony() {
    log_step "安装 chrony..."
    
    case "${OS}" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq chrony curl
            ;;
        centos)
            yum install -y chrony curl
            ;;
        alpine)
            apk add chrony curl
            ;;
        arch)
            pacman -Sy --noconfirm chrony curl
            ;;
    esac
    
    log_success "chrony 安装完成"
}

# 测试网络连接
test_network() {
    log_step "测试网络连接..."
    
    local test_hosts=("time.google.com" "time.cloudflare.com" "pool.ntp.org")
    local success=false
    
    for host in "${test_hosts[@]}"; do
        if timeout 5 curl -s "https://${host}" > /dev/null 2>&1 || \
           timeout 5 nc -zv "${host}" 123 2>/dev/null || \
           timeout 5 ping -c 1 "${host}" > /dev/null 2>&1; then
            log_success "网络连接正常: ${host}"
            success=true
            break
        fi
    done
    
    if [[ "$success" == "false" ]]; then
        log_warning "网络可能有限制，尝试备用方案..."
    fi
}

# 配置 chrony - 使用更多NTP服务器
configure_chrony() {
    log_step "配置 chrony..."
    
    local chrony_conf="/etc/chrony/chrony.conf"
    [[ "$OS" == "alpine" ]] && chrony_conf="/etc/chrony.conf"
    
    # 备份
    [[ -f "${chrony_conf}" ]] && cp "${chrony_conf}" "${chrony_conf}.bak"
    
    # 根据时区选择NTP服务器
    local ntp_servers=""
    case "${TIMEZONE}" in
        Asia/Shanghai|Asia/Chongqing|Asia/Harbin|Asia/Urumqi)
            ntp_servers="server 0.cn.pool.ntp.org iburst prefer
server 1.cn.pool.ntp.org iburst
server 2.cn.pool.ntp.org iburst
server 3.cn.pool.ntp.org iburst
server ntp.aliyun.com iburst
server ntp1.aliyun.com iburst
server time.google.com iburst"
            ;;
        Asia/Hong_Kong|Asia/Macau|Asia/Taipei)
            ntp_servers="server 0.asia.pool.ntp.org iburst
server 1.asia.pool.ntp.org iburst
server time.google.com iburst
server time.cloudflare.com iburst
server ntp1.aliyun.com iburst"
            ;;
        Asia/Tokyo|Asia/Seoul|Asia/Singapore)
            ntp_servers="server 0.asia.pool.ntp.org iburst
server 1.asia.pool.ntp.org iburst
server time.google.com iburst
server ntp.nict.jp iburst"
            ;;
        America/*)
            ntp_servers="server 0.north-america.pool.ntp.org iburst
server 1.north-america.pool.ntp.org iburst
server time.google.com iburst
server time.cloudflare.com iburst"
            ;;
        Europe/*)
            ntp_servers="server 0.europe.pool.ntp.org iburst
server 1.europe.pool.ntp.org iburst
server time.google.com iburst
server time.cloudflare.com iburst"
            ;;
        *)
            ntp_servers="server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server time.google.com iburst
server time.cloudflare.com iburst"
            ;;
    esac
    
    # 写入配置
    cat > "${chrony_conf}" << EOF
# Chrony 配置 - $(date '+%Y-%m-%d %H:%M:%S')
# IP: ${PUBLIC_IP} | 时区: ${TIMEZONE}

# NTP 服务器
${ntp_servers}

# 实时时钟同步
rtcsync

# 允许所有来源
allow

# 初始大步校正（允许大偏移快速同步）
makestep 1.0 -1

# 硬件时间戳（如果可用）
hwtimestamp *

# 日志
logdir /var/log/chrony

# 绑定地址（允许所有接口）
bindcmdaddress 0.0.0.0
bindcmdaddress ::

# 命令访问控制
cmdallow 127.0.0.1
cmdallow ::1

# 离线测量保存
dumpdir /var/lib/chrony
dumponexit
EOF
    
    log_success "chrony 配置完成"
}

# 启动 chrony 服务
start_chrony() {
    log_step "启动 chrony 服务..."
    
    case "${OS}" in
        debian)
            systemctl enable chrony 2>/dev/null || systemctl enable chronyd
            systemctl restart chrony 2>/dev/null || systemctl restart chronyd
            ;;
        centos|arch)
            systemctl enable chronyd
            systemctl restart chronyd
            ;;
        alpine)
            rc-update add chronyd default 2>/dev/null || true
            rc-service chronyd restart 2>/dev/null || /etc/init.d/chronyd restart
            ;;
    esac
    
    # 等待服务启动
    sleep 2
    log_success "chrony 服务已启动"
}

# 强制同步 - 包含重试机制
force_sync() {
    log_step "执行时间同步..."
    
    # 等待最多120秒让NTP同步
    local max_wait=120
    local waited=0
    
    echo "等待NTP同步（最多${max_wait}秒）..."
    
    while [[ $waited -lt $max_wait ]]; do
        # 强制步进
        chronyc makestep >/dev/null 2>&1
        
        # 检查同步状态
        local stratum=$(chronyc -n tracking 2>/dev/null | grep "Stratum" | awk '{print $3}')
        
        if [[ -n "$stratum" ]] && [[ "$stratum" -gt 0 ]] && [[ "$stratum" -lt 16 ]]; then
            log_success "NTP同步成功！Stratum: ${stratum}"
            return 0
        fi
        
        sleep 5
        waited=$((waited + 5))
        echo -n "."
    done
    echo ""
    
    log_warning "自动同步未完成，尝试手动同步..."
    manual_sync
}

# 手动同步 - 从HTTP获取时间
manual_sync() {
    log_step "尝试手动同步时间..."
    
    # 方法1: 从 HTTP Date 头获取时间
    local http_time=""
    for url in "https://google.com" "https://cloudflare.com" "https://taobao.com" "https://alibaba.com"; do
        http_time=$(curl -4 -s -I --max-time 10 "$url" 2>/dev/null | \
                    grep -i "^Date:" | \
                    sed 's/Date: //i' | \
                    xargs -0)
        
        if [[ -n "$http_time" ]]; then
            log_info "从 ${url} 获取时间: ${http_time}"
            break
        fi
    done
    
    if [[ -n "$http_time" ]]; then
        # 解析并设置时间
        local timestamp=$(date -d "${http_time}" +%s 2>/dev/null)
        if [[ -n "$timestamp" ]] && [[ "$timestamp" -gt 1000000000 ]]; then
            local current_ts=$(date +%s)
            local diff=$((timestamp - current_ts))
            
            log_info "当前时间偏移: ${diff} 秒"
            
            if [[ ${diff#-} -gt 10 ]]; then
                log_warning "时间偏差较大(${diff}s)，正在校准..."
                
                # 设置系统时间
                date -s "$(date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || \
                timedatectl set-time "$(date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
                
                # 同步到硬件时钟
                hwclock -w 2>/dev/null || hwclock --systohc 2>/dev/null || true
                
                log_success "手动时间同步完成"
            fi
        fi
    else
        log_warning "无法从HTTP获取时间，跳过手动同步"
    fi
    
    # 最后再试一次 chrony
    sleep 3
    chronyc makestep >/dev/null 2>&1 || true
}

# 启用 RTC 同步
enable_rtc_sync() {
    log_step "配置RTC同步..."
    
    # 同步系统时间到RTC
    hwclock --systohc --utc 2>/dev/null || hwclock --systohc 2>/dev/null || true
    
    # 配置 timedatectl
    timedatectl set-local-rtc 0 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
    
    # 确保 adjtime 配置
    cat > /etc/adjtime << 'EOF'
0.0 0 0.0
0
UTC
EOF
    
    log_success "RTC同步配置完成"
}

# 等待NTP完全同步
wait_for_sync() {
    log_step "等待NTP完全同步..."
    
    local max_wait=180
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        local tracking=$(chronyc -n tracking 2>/dev/null)
        local stratum=$(echo "$tracking" | grep "Stratum" | awk '{print $3}')
        local ref_time=$(echo "$tracking" | grep "Ref time" | awk '{print $4,$5,$6}')
        
        if [[ -n "$stratum" ]] && [[ "$stratum" -gt 0 ]] && [[ "$stratum" -lt 16 ]]; then
            if [[ "$ref_time" != *"1970"* ]]; then
                log_success "NTP已完全同步"
                return 0
            fi
        fi
        
        sleep 10
        waited=$((waited + 10))
        echo -n "."
    done
    echo ""
    
    log_warning "NTP同步可能仍在进行中"
}

# 显示详细结果
show_results() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              VPS 时区和时间校准 - 完成报告                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    echo -e "${BLUE}━━━━━ IP 信息 ━━━━━${NC}"
    echo "  公网IPv4:   ${PUBLIC_IP}"
    echo "  位置:       ${COUNTRY:-未知} / ${CITY:-未知}"
    echo ""
    
    echo -e "${BLUE}━━━━━ 时区设置 ━━━━━${NC}"
    echo "  时区:       $(cat /etc/timezone 2>/dev/null || timedatectl show --property=Timezone --value 2>/dev/null)"
    echo "  系统时间:   $(date '+%Y-%m-%d %H:%M:%S %Z %A')"
    echo "  硬件时钟:   $(hwclock -r 2>/dev/null || echo '无法读取')"
    echo "  RTC同步:    $(timedatectl show --property=RTCTimeUSec --value 2>/dev/null && echo '已启用' || echo '已配置')"
    echo ""
    
    echo -e "${BLUE}━━━━━ NTP 服务器状态 ━━━━━${NC}"
    chronyc sources -v 2>/dev/null | head -20 || echo "  无法获取状态"
    echo ""
    
    echo -e "${BLUE}━━━━━ NTP 跟踪信息 ━━━━━${NC}"
    chronyc tracking 2>/dev/null | grep -E "(Leap|Stratum|Precision|Ref time|System time|Last offset|RMS offset|Frequency|Offset)" || echo "  无法获取跟踪信息"
    echo ""
    
    echo -e "${BLUE}━━━━━ 服务状态 ━━━━━${NC}"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet chrony 2>/dev/null; then
            echo -e "  chrony:      ${GREEN}● 运行中${NC}"
        elif systemctl is-active --quiet chronyd 2>/dev/null; then
            echo -e "  chronyd:     ${GREEN}● 运行中${NC}"
        else
            echo -e "  chrony:      ${YELLOW}● 状态未知${NC}"
        fi
    fi
    
    # 最终同步检查
    echo ""
    echo -e "${BLUE}━━━━━ 同步状态 ━━━━━${NC}"
    local final_stratum=$(chronyc -n tracking 2>/dev/null | grep "Stratum" | awk '{print $3}')
    if [[ -n "$final_stratum" ]] && [[ "$final_stratum" -gt 0 ]] && [[ "$final_stratum" -lt 16 ]]; then
        echo -e "  同步状态:    ${GREEN}● 已同步 (Stratum ${final_stratum})${NC}"
    else
        echo -e "  同步状态:    ${YELLOW}● 同步中（请等待几分钟）${NC}"
        echo -e "  提示:        运行 ${CYAN}chronyc sources${NC} 查看详细状态"
    fi
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                      校准完成                                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# 主函数
main() {
    clear
    echo ""
    echo "╭────────────────────────────────────────╮"
    echo "│   VPS 时区和时间自动校准脚本 - 增强版   │"
    echo "╰────────────────────────────────────────╯"
    echo ""
    
    check_root
    detect_os
    get_public_ip
    get_timezone
    set_timezone
    install_chrony
    test_network
    configure_chrony
    start_chrony
    force_sync
    enable_rtc_sync
    wait_for_sync
    show_results
}

# 错误处理
trap 'log_error "执行出错: 第 $LINIO 行"' ERR

main "$@"
