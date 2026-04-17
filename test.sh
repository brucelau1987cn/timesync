#!/usr/bin/env bash
# =============================================================================
# VPS 时区自动校准脚本 v2.7
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash tz-calibrate.sh [--dry-run] [--force TIMEZONE] [--ntp chrony|ntpdate|timesyncd]
# =============================================================================

set -euo pipefail

trap 'echo -e "\033[0;31m[FATAL]\033[0m 脚本在第 $LINENO 行意外退出（退出码: $?）" >&2' EXIT

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ---------- 参数解析 ----------
DRY_RUN=false
FORCE_TZ=""
NTP_TOOL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --force)      FORCE_TZ="${2:-}"; shift 2 ;;
    --ntp)
      case "${2:-}" in
        chrony|ntpdate|timesyncd) NTP_TOOL="$2"; shift 2 ;;
        *) die "--ntp 参数只接受 chrony、ntpdate 或 timesyncd" ;;
      esac ;;
    -h|--help)
      cat <<'EOF'
用法: bash tz-calibrate.sh [选项]

选项:
  --dry-run                       仅检测，不修改系统
  --force TIMEZONE                强制使用指定时区，例如 Asia/Tokyo
  --ntp chrony|ntpdate|timesyncd  指定 NTP 同步工具（跳过交互选择）
  -h, --help                      显示帮助

示例:
  bash tz-calibrate.sh                        # 自动检测，交互选择 NTP 工具
  bash tz-calibrate.sh --ntp chrony           # 自动检测，强制使用 chrony
  bash tz-calibrate.sh --ntp timesyncd        # 自动检测，使用 systemd-timesyncd
  bash tz-calibrate.sh --force Asia/Tokyo     # 强制东京时区
  bash tz-calibrate.sh --dry-run              # 仅检测不修改
EOF
      trap - EXIT; exit 0 ;;
    *) die "未知参数: $1，使用 --help 查看帮助" ;;
  esac
done

# ---------- 权限检查 ----------
if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
  die "请以 root 权限运行，或使用 --dry-run 进行检测"
fi

# ---------- 依赖检查 ----------
FETCH_CMD=""
for cmd in curl wget; do
  if command -v "$cmd" &>/dev/null; then
    FETCH_CMD="$cmd"; break
  fi
done
[[ -z "$FETCH_CMD" ]] && die "需要 curl 或 wget，请先安装后重试"

http_get() {
  local url="$1"
  if [[ "$FETCH_CMD" == "curl" ]]; then
    curl -fsSL --max-time 8 "$url" 2>/dev/null
  else
    wget -qO- --timeout=8 "$url" 2>/dev/null
  fi
}

# ---------- 平台检测 ----------
detect_platform() {
  local os_name="" os_ver="" pkg_mgr="" arch="" init_sys=""
  arch=$(uname -m 2>/dev/null || echo "unknown")

  if [ -f /etc/os-release ]; then
    os_name=$(. /etc/os-release && echo "${NAME:-unknown}")
    os_ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  elif [ -f /etc/redhat-release ]; then
    os_name=$(cat /etc/redhat-release)
  elif [ -f /etc/alpine-release ]; then
    os_name="Alpine"
    os_ver=$(cat /etc/alpine-release)
  else
    os_name=$(uname -s)
  fi

  if command -v apt-get &>/dev/null; then
    pkg_mgr="apt"
  elif command -v dnf &>/dev/null; then
    pkg_mgr="dnf"
  elif command -v yum &>/dev/null; then
    pkg_mgr="yum"
  elif command -v apk &>/dev/null; then
    pkg_mgr="apk"
  elif command -v pacman &>/dev/null; then
    pkg_mgr="pacman"
  elif command -v zypper &>/dev/null; then
    pkg_mgr="zypper"
  else
    pkg_mgr="unknown"
  fi

  # 检测 init 系统
  if command -v systemctl &>/dev/null && systemctl --version &>/dev/null; then
    init_sys="systemd"
  elif command -v rc-service &>/dev/null; then
    init_sys="openrc"
  elif [ -f /etc/init.d/cron ]; then
    init_sys="sysvinit"
  else
    init_sys="unknown"
  fi

  echo "${os_name}|${os_ver}|${pkg_mgr}|${arch}|${init_sys}"
}

# ---------- NTP 工具交互选择 ----------
select_ntp_tool() {
  local init_sys="$1"

  # 如果已通过 --ntp 指定，直接返回
  if [ -n "$NTP_TOOL" ]; then
    echo "$NTP_TOOL"
    return
  fi

  # timesyncd 仅在 systemd 系统上可用
  local timesyncd_available=true
  if [ "$init_sys" != "systemd" ]; then
    timesyncd_available=false
  fi

  echo "" >&2
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}" >&2
  echo -e "${BOLD}║           选择 NTP 时间同步工具                         ║${RESET}" >&2
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}" >&2
  echo -e "${BOLD}║                                                        ║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ${GREEN}[1] chrony${RESET}  ${BOLD}⭐ 推荐${RESET}                                   ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      类型 : 后台常驻服务（守护进程）                   ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      同步 : 安装后 24/7 自动持续同步，开机自启         ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      精度 : ${GREEN}亚毫秒级${RESET}，渐进式平滑调整                  ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      优势 : 专门优化 VPS/VM 时钟漂移，断网自动恢复     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      资源 : 约 2-3MB 内存常驻                          ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      兼容 : ${GREEN}所有 Linux 发行版${RESET}                         ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      维护 : ${GREEN}活跃开发中${RESET}                                ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}                                                        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ${CYAN}[2] systemd-timesyncd${RESET}                                  ${BOLD}║${RESET}" >&2
  if $timesyncd_available; then
    echo -e "${BOLD}║${RESET}      类型 : 轻量后台服务（systemd 内置组件）           ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      同步 : 自动持续同步，开机自启                     ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      精度 : ${YELLOW}毫秒级${RESET}，基础 SNTP 协议                    ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      优势 : 最轻量，无额外依赖，Debian/Ubuntu 常预装   ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      资源 : 约 1MB 内存                                ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      兼容 : ${YELLOW}仅 systemd 系统${RESET}（不支持 Alpine 等）       ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      局限 : 不支持作为 NTP 服务器，无法精细调参         ${BOLD}║${RESET}" >&2
    echo -e "${BOLD}║${RESET}      维护 : ${GREEN}随 systemd 更新${RESET}                           ${BOLD}║${RESET}" >&2
  else
    echo -e "${BOLD}║${RESET}      ${RED}⚠ 当前系统不是 systemd，此选项不可用${RESET}             ${BOLD}║${RESET}" >&2
  fi
  echo -e "${BOLD}║${RESET}                                                        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ${YELLOW}[3] ntpdate${RESET}                                            ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      类型 : 一次性命令行工具（非守护进程）              ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      同步 : 手动执行一次校准一次，需配合 crontab        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      精度 : ${YELLOW}毫秒级${RESET}，直接跳变系统时间                  ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      劣势 : 断网后需手动再跑，大跳变可能影响日志        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      资源 : 仅运行时占资源                              ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      兼容 : ${GREEN}所有 Linux 发行版${RESET}                         ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}      维护 : ${RED}已废弃，Debian/Ubuntu 逐步移除${RESET}              ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}                                                        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}" >&2
  echo -e "${BOLD}║${RESET}                                                        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ${BOLD}对比总结:${RESET}                                              ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ┌──────────────┬──────────┬──────────┬──────────┐     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │     特性     │ ${GREEN}chrony${RESET}   │${CYAN}timesyncd${RESET} │ ${YELLOW}ntpdate${RESET}  │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  ├──────────────┼──────────┼──────────┼──────────┤     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 持续同步     │  ${GREEN}✔ 是${RESET}   │  ${GREEN}✔ 是${RESET}   │  ${RED}✘ 否${RESET}   │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 开机自启     │  ${GREEN}✔ 是${RESET}   │  ${GREEN}✔ 是${RESET}   │  ${RED}✘ 否${RESET}   │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 精度         │ ${GREEN}亚毫秒${RESET}  │ ${YELLOW}毫秒${RESET}    │ ${YELLOW}毫秒${RESET}    │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ VPS优化      │  ${GREEN}✔ 有${RESET}   │  ${RED}✘ 无${RESET}   │  ${RED}✘ 无${RESET}   │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 断网恢复     │ ${GREEN}自动${RESET}    │ ${GREEN}自动${RESET}    │ ${YELLOW}手动${RESET}    │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 内存占用     │ ${YELLOW}2-3MB${RESET}   │ ${GREEN}~1MB${RESET}    │ ${GREEN}0${RESET}       │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 兼容性       │ ${GREEN}全平台${RESET}  │ ${YELLOW}systemd${RESET} │ ${GREEN}全平台${RESET}  │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  │ 维护状态     │ ${GREEN}活跃${RESET}    │ ${GREEN}活跃${RESET}    │ ${RED}废弃${RESET}    │     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}  └──────────────┴──────────┴──────────┴──────────┘     ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}║${RESET}                                                        ${BOLD}║${RESET}" >&2
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}" >&2
  echo "" >&2

  local choice=""
  local timeout_sec=15
  local valid_options="1/2/3"
  if ! $timesyncd_available; then
    valid_options="1/3（选项 2 不可用）"
  fi

  if [ -t 0 ]; then
    echo -e "请选择 [${valid_options}]（${timeout_sec} 秒内无输入默认选 1-chrony）: \c" >&2
    if read -t "$timeout_sec" -r choice 2>/dev/null; then
      true
    else
      echo "" >&2
      info "超时未输入，使用默认选择"
      choice="1"
    fi
  else
    info "非交互模式，自动选择默认: chrony"
    choice="1"
  fi

  case "$choice" in
    2)
      if $timesyncd_available; then
        info "已选择: systemd-timesyncd"
        echo "timesyncd"
      else
        warn "当前系统不支持 timesyncd，自动切换为 chrony"
        echo "chrony"
      fi
      ;;
    3)
      info "已选择: ntpdate"
      echo "ntpdate"
      ;;
    *)
      info "已选择: chrony（推荐）"
      echo "chrony"
      ;;
  esac
}

# ---------- 国家 → 时区回退表 ----------
declare -A COUNTRY_TZ=(
  [CN]="Asia/Shanghai"     [JP]="Asia/Tokyo"        [KR]="Asia/Seoul"
  [SG]="Asia/Singapore"    [HK]="Asia/Hong_Kong"    [TW]="Asia/Taipei"
  [TH]="Asia/Bangkok"      [VN]="Asia/Ho_Chi_Minh"  [MY]="Asia/Kuala_Lumpur"
  [ID]="Asia/Jakarta"      [PH]="Asia/Manila"       [IN]="Asia/Kolkata"
  [PK]="Asia/Karachi"      [BD]="Asia/Dhaka"        [LK]="Asia/Colombo"
  [NP]="Asia/Kathmandu"    [AE]="Asia/Dubai"        [SA]="Asia/Riyadh"
  [QA]="Asia/Qatar"        [KW]="Asia/Kuwait"       [IL]="Asia/Jerusalem"
  [TR]="Europe/Istanbul"   [RU]="Europe/Moscow"     [DE]="Europe/Berlin"
  [FR]="Europe/Paris"      [GB]="Europe/London"     [NL]="Europe/Amsterdam"
  [IT]="Europe/Rome"       [ES]="Europe/Madrid"     [PL]="Europe/Warsaw"
  [SE]="Europe/Stockholm"  [NO]="Europe/Oslo"       [FI]="Europe/Helsinki"
  [CH]="Europe/Zurich"     [AT]="Europe/Vienna"     [PT]="Europe/Lisbon"
  [US]="America/New_York"  [CA]="America/Toronto"   [MX]="America/Mexico_City"
  [BR]="America/Sao_Paulo" [AR]="America/Argentina/Buenos_Aires"
  [CL]="America/Santiago"  [CO]="America/Bogota"    [PE]="America/Lima"
  [AU]="Australia/Sydney"  [NZ]="Pacific/Auckland"  [ZA]="Africa/Johannesburg"
  [NG]="Africa/Lagos"      [EG]="Africa/Cairo"      [KE]="Africa/Nairobi"
)

# ---------- 验证时区合法性 ----------
validate_timezone() {
  local tz="$1"
  for base in /usr/share/zoneinfo /usr/lib/zoneinfo /usr/share/lib/zoneinfo; do
    [[ -f "${base}/${tz}" ]] && return 0
  done
  return 1
}

# ---------- 查找 zoneinfo 基础路径 ----------
find_zoneinfo_base() {
  for base in /usr/share/zoneinfo /usr/lib/zoneinfo /usr/share/lib/zoneinfo; do
    [[ -d "$base" ]] && echo "$base" && return 0
  done
  die "找不到 zoneinfo 数据库，请安装 tzdata 包"
}

# ---------- 获取 IP 和时区信息 ----------
detect_timezone() {
  info "正在检测公网 IP 归属地..."

  local tz="" country="" ip="" city="" resp=""

  resp=$(http_get "https://ipinfo.io/json") || resp=""
  if [[ -n "$resp" ]]; then
    ip=$(echo "$resp"      | grep -oP '"ip"\s*:\s*"\K[^"]+' || true)
    country=$(echo "$resp" | grep -oP '"country"\s*:\s*"\K[^"]+' || true)
    city=$(echo "$resp"    | grep -oP '"city"\s*:\s*"\K[^"]+' || true)
    tz=$(echo "$resp"      | grep -oP '"timezone"\s*:\s*"\K[^"]+' || true)
    info "公网 IP: ${ip:-未知}  位置: ${city:-?}, ${country:-?}"
  fi

  if [[ -z "$tz" ]]; then
    warn "ipinfo.io 未返回时区，尝试 ip-api.com..."
    resp=$(http_get "http://ip-api.com/json?fields=status,countryCode,timezone,city,query") || resp=""
    if [[ -n "$resp" ]]; then
      local status
      status=$(echo "$resp" | grep -oP '"status"\s*:\s*"\K[^"]+' || true)
      if [[ "$status" == "success" ]]; then
        [[ -z "$ip" ]]      && ip=$(echo "$resp"      | grep -oP '"query"\s*:\s*"\K[^"]+' || true)
        [[ -z "$country" ]] && country=$(echo "$resp" | grep -oP '"countryCode"\s*:\s*"\K[^"]+' || true)
        [[ -z "$city" ]]    && city=$(echo "$resp"    | grep -oP '"city"\s*:\s*"\K[^"]+' || true)
        tz=$(echo "$resp"   | grep -oP '"timezone"\s*:\s*"\K[^"]+' || true)
      fi
    fi
  fi

  if [[ -z "$tz" && -n "$country" ]]; then
    warn "API 未返回时区字段，使用国家代码 [${country}] 查询回退表"
    tz="${COUNTRY_TZ[$country]:-}"
    [[ -z "$tz" ]] && die "国家 [${country}] 不在回退表中，请使用 --force 手动指定时区"
  fi

  [[ -z "$tz" ]] && die "无法获取时区信息。请检查网络，或使用 --force TIMEZONE 手动指定"

  echo "$tz"
}

# ---------- 设置系统时区 ----------
apply_timezone() {
  local tz="$1"

  if ! validate_timezone "$tz"; then
    die "时区 [${tz}] 无效或 zoneinfo 文件不存在，请确认系统已安装 tzdata"
  fi

  if $DRY_RUN; then
    info "[dry-run] 将设置时区为: ${tz}"
    return
  fi

  if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone "$tz"
    success "已通过 timedatectl 设置时区: ${tz}"
  else
    local zoneinfo_base
    zoneinfo_base=$(find_zoneinfo_base)
    ln -sf "${zoneinfo_base}/${tz}" /etc/localtime
    echo "$tz" > /etc/timezone
    success "已通过软链接设置时区: ${tz}"
  fi
}

# ---------- 安装指定 NTP 工具 ----------
install_ntp_tool() {
  local tool="$1" pkg_mgr="$2"
  local pkg_name="$tool"
  local install_ok=false

  # 映射包名
  case "$tool" in
    timesyncd)
      case "$pkg_mgr" in
        apt) pkg_name="systemd-timesyncd" ;;
        *)   pkg_name="systemd" ;;
      esac
      ;;
  esac

  info "正在安装 ${pkg_name}..."

  case "$pkg_mgr" in
    apt)
      info "[apt] 更新索引..."
      apt-get update -qq 2>/dev/null
      info "[apt] 安装 ${pkg_name}..."
      if apt-get install -y -qq "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    dnf)
      info "[dnf] 安装 ${pkg_name}..."
      if dnf install -y -q "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    yum)
      info "[yum] 安装 ${pkg_name}..."
      if yum install -y -q "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    apk)
      info "[apk] 安装 ${pkg_name}..."
      if apk add --quiet "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    pacman)
      info "[pacman] 安装 ${pkg_name}..."
      if pacman -Sy --noconfirm "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    zypper)
      info "[zypper] 安装 ${pkg_name}..."
      if zypper install -y "$pkg_name" 2>/dev/null; then install_ok=true; fi
      ;;
    *)
      warn "未识别的包管理器 [${pkg_mgr}]，无法自动安装"
      return 1
      ;;
  esac

  if $install_ok; then
    success "${pkg_name} 安装成功"
    return 0
  else
    warn "${pkg_name} 安装失败"
    return 1
  fi
}

# ---------- chrony 同步 ----------
sync_with_chrony() {
  info "启动 chronyd 服务..."
  if command -v systemctl &>/dev/null; then
    systemctl enable --now chronyd 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-service chronyd start 2>/dev/null || true
    rc-update add chronyd default 2>/dev/null || true
  else
    chronyd 2>/dev/null || true
  fi

  info "等待 chrony 锁定 NTP 源（最多 15 秒）..."
  local j=1
  while [ "$j" -le 15 ]; do
    sleep 1
    local sources
    sources=$(chronyc sources 2>/dev/null | grep '^\^\*' || true)
    if [ -n "$sources" ]; then
      success "chrony 已锁定 NTP 源"
      break
    fi
    j=$((j + 1))
  done

  if chronyc makestep &>/dev/null; then
    return 0
  else
    local offset
    offset=$(chronyc tracking 2>/dev/null | grep "System time" | grep -oP '[\d.]+' | head -1 || echo "")
    if [ -n "$offset" ]; then
      info "当前时钟偏差: ${offset} 秒"
      return 0
    fi
    return 1
  fi
}

# ---------- timesyncd 同步 ----------
sync_with_timesyncd() {
  info "启动 systemd-timesyncd 服务..."
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  timedatectl set-ntp true 2>/dev/null || true

  info "等待 timesyncd 同步（最多 20 秒）..."
  local i=1
  while [ "$i" -le 20 ]; do
    sleep 1
    local ntp_status
    ntp_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "")
    if [ "$ntp_status" = "yes" ]; then
      success "systemd-timesyncd 时间同步完成（等待 ${i} 秒）"
      return 0
    fi
    i=$((i + 1))
  done

  warn "systemd-timesyncd 同步等待超时（20 秒）"
  return 1
}

# ---------- ntpdate 同步 + crontab ----------
sync_with_ntpdate() {
  if ntpdate -u pool.ntp.org 2>/dev/null; then
    info "设置 crontab 每小时自动同步..."
    local ntpdate_path
    ntpdate_path=$(command -v ntpdate)
    local cron_line="0 * * * * ${ntpdate_path} -u pool.ntp.org >/dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -qF "ntpdate"; then
      info "crontab 中已存在 ntpdate 任务，跳过"
    else
      (crontab -l 2>/dev/null; echo "$cron_line") | crontab - 2>/dev/null
      if [ $? -eq 0 ]; then
        success "已添加 crontab: 每小时自动同步"
      else
        warn "crontab 添加失败，请手动设置定时同步"
      fi
    fi
    return 0
  else
    return 1
  fi
}

# =========================================================================
# 关闭 set -e 进入同步 + 报告阶段
# =========================================================================
sync_and_report() {
  set +e
  set +o pipefail

  local target_tz="$1"
  local sync_ok=false
  local sync_method=""

  # ==================== 平台检测 ====================
  local platform_info os_name os_ver pkg_mgr arch init_sys
  platform_info=$(detect_platform)
  os_name=$(echo "$platform_info"  | cut -d'|' -f1)
  os_ver=$(echo "$platform_info"   | cut -d'|' -f2)
  pkg_mgr=$(echo "$platform_info"  | cut -d'|' -f3)
  arch=$(echo "$platform_info"     | cut -d'|' -f4)
  init_sys=$(echo "$platform_info" | cut -d'|' -f5)

  echo "" >&2
  echo -e "${BOLD}------------ 系统平台信息 ------------${RESET}" >&2
  echo -e "  操作系统  : ${CYAN}${os_name} ${os_ver}${RESET}" >&2
  echo -e "  系统架构  : ${CYAN}${arch}${RESET}" >&2
  echo -e "  包管理器  : ${CYAN}${pkg_mgr}${RESET}" >&2
  echo -e "  Init 系统 : ${CYAN}${init_sys}${RESET}" >&2
  echo -e "${BOLD}--------------------------------------${RESET}" >&2
  echo "" >&2

  # ==================== NTP 工具检测 ====================
  info "检测 NTP 同步工具..."
  local has_chrony=false has_ntpdate=false has_timesyncd=false
  local need_install=false

  if command -v chronyc &>/dev/null; then
    has_chrony=true
    local chrony_ver
    chrony_ver=$(chronyc -v 2>/dev/null | head -1 || echo "")
    success "chronyc     ✔ 已安装  ${chrony_ver}"
  else
    warn "chronyc     ✘ 未安装"
  fi

  if command -v ntpdate &>/dev/null; then
    has_ntpdate=true
    success "ntpdate     ✔ 已安装 ($(command -v ntpdate))"
  else
    warn "ntpdate     ✘ 未安装"
  fi

  if command -v timedatectl &>/dev/null; then
    local ntp_svc
    ntp_svc=$(timedatectl status 2>/dev/null | grep -i "NTP service" || true)
    if echo "$ntp_svc" | grep -qi "n/a"; then
      warn "timesyncd   ✘ 未安装（NTP service: n/a）"
    elif echo "$ntp_svc" | grep -qi "inactive"; then
      warn "timesyncd   ○ 已安装但未启用"
      has_timesyncd=true
    else
      has_timesyncd=true
      success "timesyncd   ✔ 可用"
    fi
  fi

  # 判断是否需要安装
  if ! $has_chrony && ! $has_ntpdate && ! $has_timesyncd; then
    need_install=true
  fi

  if $DRY_RUN; then
    info "[dry-run] 将执行网络时间同步"
    if $need_install; then
      info "[dry-run] 检测到缺少 NTP 工具，将提示安装"
    fi
  else
    info "正在同步网络时间..."

    # ---- 1. chrony（已安装） ----
    if $has_chrony; then
      info "使用已安装的 chrony 同步..."
      if sync_with_chrony; then
        sync_ok=true
        sync_method="chrony"
        success "chrony 时间同步完成"
      else
        warn "chrony 同步失败"
      fi
    fi

    # ---- 2. ntpdate（已安装） ----
    if ! $sync_ok && $has_ntpdate; then
      info "使用已安装的 ntpdate 同步..."
      if sync_with_ntpdate; then
        sync_ok=true
        sync_method="ntpdate"
        success "ntpdate 时间同步完成"
      else
        warn "ntpdate 同步失败"
      fi
    fi

    # ---- 3. timesyncd（已安装） ----
    if ! $sync_ok && $has_timesyncd; then
      info "使用已安装的 systemd-timesyncd 同步..."
      if sync_with_timesyncd; then
        sync_ok=true
        sync_method="systemd-timesyncd"
      else
        warn "systemd-timesyncd 同步失败"
      fi
    fi

    # ---- 4. 无可用工具 → 选择安装 ----
    if ! $sync_ok && $need_install; then
      echo "" >&2
      warn "系统中没有可用的 NTP 时间同步工具"

      local chosen_tool
      chosen_tool=$(select_ntp_tool "$init_sys")

      echo "" >&2
      echo -e "${BOLD}------------ 安装信息 ----------------${RESET}" >&2
      echo -e "  安装平台  : ${CYAN}${os_name} ${os_ver} (${arch})${RESET}" >&2
      echo -e "  包管理器  : ${CYAN}${pkg_mgr}${RESET}" >&2
      echo -e "  安装工具  : ${GREEN}${chosen_tool}${RESET}" >&2
      echo -e "${BOLD}--------------------------------------${RESET}" >&2
      echo "" >&2

      if install_ntp_tool "$chosen_tool" "$pkg_mgr"; then
        case "$chosen_tool" in
          chrony)
            if command -v chronyc &>/dev/null; then
              if sync_with_chrony; then
                sync_ok=true
                sync_method="chrony（自动安装 via ${pkg_mgr}）"
                success "chrony 时间同步完成"
              else
                warn "chrony 已安装但同步未确认"
                sync_method="chrony（已安装，同步状态未知）"
              fi
            fi
            ;;
          timesyncd)
            if sync_with_timesyncd; then
              sync_ok=true
              sync_method="systemd-timesyncd（自动安装 via ${pkg_mgr}）"
              success "systemd-timesyncd 时间同步完成"
            else
              warn "timesyncd 已安装但同步未确认"
            fi
            ;;
          ntpdate)
            if command -v ntpdate &>/dev/null; then
              if sync_with_ntpdate; then
                sync_ok=true
                sync_method="ntpdate（自动安装 via ${pkg_mgr}）"
                success "ntpdate 时间同步完成"
              else
                warn "ntpdate 已安装但同步失败"
              fi
            fi
            ;;
        esac
      else
        warn "${chosen_tool} 安装失败"
      fi
    fi

    # ---- 5. 终极回退：HTTP 响应头强制校时 ----
    if ! $sync_ok; then
      echo "" >&2
      info "所有 NTP 方式均失败，尝试 HTTP 响应头校时（最后手段）..."
      local http_date=""
      if command -v curl &>/dev/null; then
        http_date=$(curl -sI --max-time 5 "https://www.google.com" 2>/dev/null \
          | grep -i "^date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')
      fi
      if [ -z "$http_date" ] && command -v wget &>/dev/null; then
        http_date=$(wget -qS --spider --timeout=5 "https://www.google.com" 2>&1 \
          | grep -i "Date:" | head -1 | sed 's/.*Date: *//' | tr -d '\r')
      fi

      if [ -n "$http_date" ]; then
        info "HTTP 服务器时间: ${http_date}"
        if date -s "$http_date" &>/dev/null; then
          sync_ok=true
          sync_method="HTTP 响应头（date -s）"
          success "已通过 HTTP 响应头校准系统时间"
        else
          local epoch
          epoch=$(date -d "$http_date" +%s 2>/dev/null || true)
          if [ -n "$epoch" ]; then
            date -s "@${epoch}" &>/dev/null
            sync_ok=true
            sync_method="HTTP 响应头（epoch）"
            success "已通过 HTTP 响应头校准系统时间"
          else
            warn "HTTP 时间格式无法解析"
          fi
        fi
      else
        warn "无法获取 HTTP 服务器时间"
      fi
    fi

    # ---- 同步后写入硬件时钟 ----
    if $sync_ok && command -v hwclock &>/dev/null; then
      hwclock -w 2>/dev/null && info "已同步写入硬件时钟（RTC）" || true
    fi
  fi

  # ==================== 结果汇总 ====================
  echo "" >&2
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}" >&2
  echo -e "${BOLD}║           时区校准结果汇总                   ║${RESET}" >&2
  echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}" >&2
  echo -e "${BOLD}║${RESET}  系统平台  : ${CYAN}${os_name} ${os_ver} (${arch})${RESET}" >&2
  echo -e "${BOLD}║${RESET}  Init 系统 : ${CYAN}${init_sys}${RESET}" >&2
  echo -e "${BOLD}║${RESET}  包管理器  : ${CYAN}${pkg_mgr}${RESET}" >&2
  echo -e "${BOLD}║${RESET}  校准时区  : ${GREEN}${target_tz}${RESET}" >&2

  if ! $DRY_RUN; then
    local local_time utc_time
    local_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    utc_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    echo -e "${BOLD}║${RESET}  本地时间  : ${GREEN}${local_time}${RESET}" >&2
    echo -e "${BOLD}║${RESET}  UTC 时间  : ${utc_time}" >&2

    if $sync_ok; then
      echo -e "${BOLD}║${RESET}  同步状态  : ${GREEN}✔ 已同步（${sync_method}）${RESET}" >&2
    else
      echo -e "${BOLD}║${RESET}  同步状态  : ${YELLOW}✘ 未同步${RESET}" >&2
    fi

    # 网络参考时间
    local net_time=""
    if command -v curl &>/dev/null; then
      net_time=$(curl -sI --max-time 5 "https://www.google.com" 2>/dev/null \
        | grep -i "^date:" | sed 's/^[Dd]ate: *//' | tr -d '\r')
    fi
    if [ -z "$net_time" ] && command -v wget &>/dev/null; then
      net_time=$(wget -qS --spider --timeout=5 "https://www.google.com" 2>&1 \
        | grep -i "Date:" | head -1 | sed 's/.*Date: *//' | tr -d '\r')
    fi

    if [ -n "$net_time" ]; then
      local net_epoch local_epoch diff_sec=""
      net_epoch=$(date -d "$net_time" +%s 2>/dev/null || true)
      local_epoch=$(date +%s 2>/dev/null || true)
      if [ -n "$net_epoch" ] && [ -n "$local_epoch" ]; then
        diff_sec=$((local_epoch - net_epoch))
        if [ "$diff_sec" -lt 0 ] 2>/dev/null; then
          diff_sec=$(( -diff_sec ))
        fi
      fi

      echo -e "${BOLD}║${RESET}  网络参考  : ${CYAN}${net_time}${RESET}" >&2
      if [ -n "$diff_sec" ]; then
        if [ "$diff_sec" -le 2 ]; then
          echo -e "${BOLD}║${RESET}  时间偏差  : ${GREEN}≤ ${diff_sec} 秒 ✔ 精准${RESET}" >&2
        elif [ "$diff_sec" -le 10 ]; then
          echo -e "${BOLD}║${RESET}  时间偏差  : ${YELLOW}约 ${diff_sec} 秒（可接受）${RESET}" >&2
        else
          echo -e "${BOLD}║${RESET}  时间偏差  : ${RED}约 ${diff_sec} 秒（偏差较大！）${RESET}" >&2
        fi
      fi
    fi

    echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}" >&2
    echo -e "${BOLD}║${RESET}  ${BOLD}[ NTP 工具最终状态 ]${RESET}" >&2

    if command -v chronyc &>/dev/null; then
      local chrony_svc_status
      chrony_svc_status=$(systemctl is-active chronyd 2>/dev/null || echo "unknown")
      echo -e "${BOLD}║${RESET}    chrony:      ${GREEN}已安装${RESET} | 服务: ${chrony_svc_status}" >&2
    else
      echo -e "${BOLD}║${RESET}    chrony:      ${YELLOW}未安装${RESET}" >&2
    fi

    if command -v ntpdate &>/dev/null; then
      echo -n -e "${BOLD}║${RESET}    ntpdate:     ${GREEN}已安装${RESET}" >&2
      if crontab -l 2>/dev/null | grep -qF "ntpdate"; then
        echo -e " | ${GREEN}crontab 每小时同步 ✔${RESET}" >&2
      else
        echo -e " | ${YELLOW}无定时任务${RESET}" >&2
      fi
    else
      echo -e "${BOLD}║${RESET}    ntpdate:     ${YELLOW}未安装${RESET}" >&2
    fi

    local final_ntp_svc
    final_ntp_svc=$(timedatectl status 2>/dev/null | grep -i "NTP service" | sed 's/.*: *//' || echo "unknown")
    local final_synced
    final_synced=$(timedatectl status 2>/dev/null | grep -i "synchronized" | sed 's/.*: *//' || echo "unknown")
    echo -e "${BOLD}║${RESET}    NTP service:  ${final_ntp_svc}" >&2
    echo -e "${BOLD}║${RESET}    Clock synced: ${final_synced}" >&2

    # timedatectl 详情
    if command -v timedatectl &>/dev/null; then
      echo -e "${BOLD}╠══════════════════════════════════════════════╣${RESET}" >&2
      echo -e "${BOLD}║${RESET}  ${BOLD}[ timedatectl 完整状态 ]${RESET}" >&2
      timedatectl status 2>/dev/null | while IFS= read -r line; do
        echo -e "${BOLD}║${RESET}    $line" >&2
      done
    fi
  else
    echo -e "${BOLD}║${RESET}  同步状态  : ${YELLOW}dry-run 模式，未执行${RESET}" >&2
  fi

  echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}" >&2
}

# ---------- 主流程 ----------
main() {
  echo "" >&2
  echo -e "${BOLD}========== VPS 时区自动校准脚本 v2.7 ==========${RESET}" >&2
  $DRY_RUN && warn "dry-run 模式：仅检测，不修改系统"
  echo "" >&2

  local target_tz=""

  if [[ -n "$FORCE_TZ" ]]; then
    info "使用强制指定时区: ${FORCE_TZ}"
    target_tz="$FORCE_TZ"
  else
    target_tz=$(detect_timezone)
  fi

  info "目标时区: ${target_tz}"

  local current_tz=""
  current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
  [[ -z "$current_tz" ]] && current_tz=$(cat /etc/timezone 2>/dev/null || true)
  [[ -z "$current_tz" ]] && current_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
  [[ -z "$current_tz" ]] && current_tz="unknown"

  if [[ "$current_tz" == "$target_tz" ]]; then
    success "当前时区 [${current_tz}] 已与目标一致，无需修改"
  else
    info "当前时区: ${current_tz} → 目标时区: ${target_tz}"
    apply_timezone "$target_tz"
  fi

  sync_and_report "$target_tz"

  trap - EXIT
  exit
