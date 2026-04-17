#!/usr/bin/env bash
# =============================================================================
# VPS 时区自动校准脚本 v2.5
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等主流发行版
# 用法：bash tz-calibrate.sh [--dry-run] [--force TIMEZONE]
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --force)      FORCE_TZ="${2:-}"; shift 2 ;;
    -h|--help)
      echo "用法: $0 [--dry-run] [--force TIMEZONE]"
      echo "  --dry-run          仅检测，不修改系统"
      echo "  --force TIMEZONE   强制使用指定时区，例如 Asia/Tokyo"
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
  local os_name="" os_ver="" pkg_mgr="" arch=""
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

  echo "${os_name}|${os_ver}|${pkg_mgr}|${arch}"
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

# =========================================================================
# 关闭 set -e 进入时间同步 + 报告阶段
# =========================================================================
sync_and_report() {
  set +e
  set +o pipefail

  local target_tz="$1"
  local sync_ok=false
  local sync_method=""

  # ==================== 平台检测 ====================
  local platform_info os_name os_ver pkg_mgr arch
  platform_info=$(detect_platform)
  os_name=$(echo "$platform_info" | cut -d'|' -f1)
  os_ver=$(echo "$platform_info"  | cut -d'|' -f2)
  pkg_mgr=$(echo "$platform_info" | cut -d'|' -f3)
  arch=$(echo "$platform_info"    | cut -d'|' -f4)

  echo "" >&2
  echo -e "${BOLD}------------ 系统平台信息 ------------${RESET}" >&2
  echo -e "  操作系统  : ${CYAN}${os_name} ${os_ver}${RESET}" >&2
  echo -e "  系统架构  : ${CYAN}${arch}${RESET}" >&2
  echo -e "  包管理器  : ${CYAN}${pkg_mgr}${RESET}" >&2
  echo -e "${BOLD}--------------------------------------${RESET}" >&2
  echo "" >&2

  # ==================== NTP 工具检测 ====================
  info "检测 NTP 同步工具..."
  local has_chrony=false has_ntpdate=false has_timesyncd=false

  if command -v chronyc &>/dev/null; then
    has_chrony=true
    success "chronyc     ✔ 已安装 ($(command -v chronyc))"
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
    else
      has_timesyncd=true
      success "timesyncd   ✔ 可用"
    fi
  fi

  if $DRY_RUN; then
    info "[dry-run] 将执行网络时间同步"
  else
    info "正在同步网络时间..."

    # ---- 1. chrony（已安装） ----
    if $has_chrony; then
      info "使用 chrony 同步..."
      systemctl start chronyd 2>/dev/null || service chronyd start 2>/dev/null || true
      sleep 1
      if chronyc makestep &>/dev/null; then
        sync_ok=true
        sync_method="chrony"
        success "chrony 时间同步完成"
      else
        warn "chronyc makestep 失败（chronyd 可能未正常运行）"
      fi
    fi

    # ---- 2. ntpdate（已安装） ----
    if ! $sync_ok && $has_ntpdate; then
      info "使用 ntpdate 同步..."
      if ntpdate -u pool.ntp.org &>/dev/null; then
        sync_ok=true
        sync_method="ntpdate"
        success "ntpdate 时间同步完成"
      else
        warn "ntpdate 执行失败"
      fi
    fi

    # ---- 3. systemd-timesyncd（可用） ----
    if ! $sync_ok && $has_timesyncd; then
      info "使用 systemd-timesyncd 同步..."
      timedatectl set-ntp true 2>/dev/null
      local i=1
      while [ "$i" -le 15 ]; do
        sleep 1
        local ntp_status
        ntp_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "")
        if [ "$ntp_status" = "yes" ]; then
          sync_ok=true
          sync_method="systemd-timesyncd（等待 ${i} 秒）"
          success "systemd-timesyncd 时间同步完成（等待 ${i} 秒）"
          break
        fi
        i=$((i + 1))
      done
      if ! $sync_ok; then
        warn "systemd-timesyncd 同步等待超时（15 秒）"
      fi
    fi

    # ---- 4. 全部不可用 → 自动安装 chrony ----
    if ! $sync_ok; then
      echo "" >&2
      info "没有可用的 NTP 工具，自动安装 chrony..."
      echo -e "  ${BOLD}安装平台: ${CYAN}${os_name} ${os_ver}${RESET} | 包管理器: ${CYAN}${pkg_mgr}${RESET}" >&2
      echo "" >&2

      local install_ok=false

      case "$pkg_mgr" in
        apt)
          info "[apt] 正在更新索引..."
          apt-get update -qq 2>/dev/null
          info "[apt] 正在安装 chrony..."
          if apt-get install -y -qq chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        dnf)
          info "[dnf] 正在安装 chrony..."
          if dnf install -y -q chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        yum)
          info "[yum] 正在安装 chrony..."
          if yum install -y -q chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        apk)
          info "[apk] 正在安装 chrony..."
          if apk add --quiet chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        pacman)
          info "[pacman] 正在安装 chrony..."
          if pacman -Sy --noconfirm chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        zypper)
          info "[zypper] 正在安装 chrony..."
          if zypper install -y chrony 2>/dev/null; then
            install_ok=true
          fi
          ;;
        *)
          warn "未识别的包管理器 [${pkg_mgr}]，无法自动安装"
          warn "请手动安装: chrony 或 ntpdate"
          ;;
      esac

      if $install_ok && command -v chronyc &>/dev/null; then
        success "chrony 安装成功"

        # 启动 chronyd
        info "正在启动 chronyd 服务..."
        if command -v systemctl &>/dev/null; then
          systemctl enable --now chronyd 2>/dev/null || true
        elif command -v rc-service &>/dev/null; then
          rc-service chronyd start 2>/dev/null || true
          rc-update add chronyd default 2>/dev/null || true
        else
          chronyd 2>/dev/null || true
        fi

        info "等待 chrony 首次同步（最多 15 秒）..."
        local j=1
        while [ "$j" -le 15 ]; do
          sleep 1
          # 检查是否已同步到源
          local sources
          sources=$(chronyc sources 2>/dev/null | grep '^\^\*' || true)
          if [ -n "$sources" ]; then
            success "chrony 已锁定 NTP 源"
            break
          fi
          j=$((j + 1))
        done

        if chronyc makestep &>/dev/null; then
          sync_ok=true
          sync_method="chrony（自动安装 via ${pkg_mgr}）"
          success "chrony 时间同步完成"
        else
          # makestep 可能在偏差很小时不需要跳步
          local offset
          offset=$(chronyc tracking 2>/dev/null | grep "System time" | grep -oP '[\d.]+' | head -1 || echo "")
          if [ -n "$offset" ]; then
            sync_ok=true
            sync_method="chrony（自动安装，偏差 ${offset}s）"
            info "当前时钟偏差: ${offset} 秒"
          else
            warn "chrony 已安装但同步结果未知"
          fi
        fi
      elif $install_ok; then
        warn "chrony 包已安装但 chronyc 命令不可用"
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
  echo -e "${BOLD}============================================${RESET}" >&2
  echo -e "${BOLD}           时区校准结果汇总${RESET}" >&2
  echo -e "${BOLD}============================================${RESET}" >&2
  echo -e "  系统平台  : ${CYAN}${os_name} ${os_ver} (${arch})${RESET}" >&2
  echo -e "  包管理器  : ${CYAN}${pkg_mgr}${RESET}" >&2
  echo -e "  校准时区  : ${GREEN}${target_tz}${RESET}" >&2

  if ! $DRY_RUN; then
    local local_time utc_time
    local_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    utc_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

    echo -e "  本地时间  : ${GREEN}${local_time}${RESET}" >&2
    echo -e "  UTC 时间  : ${utc_time}" >&2

    if $sync_ok; then
      echo -e "  同步状态  : ${GREEN}✔ 已同步（${sync_method}）${RESET}" >&2
    else
      echo -e "  同步状态  : ${YELLOW}✘ 未同步${RESET}" >&2
    fi

    # 获取网络参考时间对比
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

      echo -e "  网络参考  : ${CYAN}${net_time}${RESET}" >&2
      if [ -n "$diff_sec" ]; then
        if [ "$diff_sec" -le 2 ]; then
          echo -e "  时间偏差  : ${GREEN}≤ ${diff_sec} 秒 ✔ 精准${RESET}" >&2
        elif [ "$diff_sec" -le 10 ]; then
          echo -e "  时间偏差  : ${YELLOW}约 ${diff_sec} 秒（可接受）${RESET}" >&2
        else
          echo -e "  时间偏差  : ${RED}约 ${diff_sec} 秒（偏差较大！）${RESET}" >&2
        fi
      fi
    fi

    echo -e "${BOLD}--------------------------------------------${RESET}" >&2

    # NTP 工具最终状态
    echo -e "  ${BOLD}[ NTP 工具状态 ]${RESET}" >&2
    if command -v chronyc &>/dev/null; then
      local chrony_status
      chrony_status=$(systemctl is-active chronyd 2>/dev/null || echo "unknown")
      echo -e "    chrony:      ${GREEN}已安装${RESET} | 服务: ${chrony_status}" >&2
    else
      echo -e "    chrony:      ${YELLOW}未安装${RESET}" >&2
    fi
    if command -v ntpdate &>/dev/null; then
      echo -e "    ntpdate:     ${GREEN}已安装${RESET}" >&2
    else
      echo -e "    ntpdate:     ${YELLOW}未安装${RESET}" >&2
    fi
    local final_ntp_svc
    final_ntp_svc=$(timedatectl status 2>/dev/null | grep -i "NTP service" | sed 's/.*: *//' || echo "unknown")
    echo -e "    NTP service: ${final_ntp_svc}" >&2

    # timedatectl 详情
    if command -v timedatectl &>/dev/null; then
      echo "" >&2
      echo -e "  ${BOLD}[ timedatectl 状态 ]${RESET}" >&2
      timedatectl status 2>/dev/null | while IFS= read -r line; do
        echo "    $line" >&2
      done
    fi
  else
    echo -e "  同步状态  : ${YELLOW}dry-run 模式，未执行${RESET}" >&2
  fi

  echo -e "${BOLD}============================================${RESET}" >&2
}

# ---------- 主流程 ----------
main() {
  echo "" >&2
  echo -e "${BOLD}========== VPS 时区自动校准脚本 v2.5 ==========${RESET}" >&2
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
  exit 0
}

main "$@"
