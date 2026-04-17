#!/usr/bin/env bash
# =============================================================================
# VPS 时区自动校准脚本 v2.2
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine 等主流发行版
# 用法：bash tz-calibrate.sh [--dry-run] [--force TIMEZONE]
# =============================================================================

set -euo pipefail

# ---------- 颜色输出（全部输出到 stderr，避免污染命令替换） ----------
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
      exit 0 ;;
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

  # 尝试 ipinfo.io
  resp=$(http_get "https://ipinfo.io/json") || resp=""
  if [[ -n "$resp" ]]; then
    ip=$(echo "$resp"      | grep -oP '"ip"\s*:\s*"\K[^"]+' || true)
    country=$(echo "$resp" | grep -oP '"country"\s*:\s*"\K[^"]+' || true)
    city=$(echo "$resp"    | grep -oP '"city"\s*:\s*"\K[^"]+' || true)
    tz=$(echo "$resp"      | grep -oP '"timezone"\s*:\s*"\K[^"]+' || true)
    info "公网 IP: ${ip:-未知}  位置: ${city:-?}, ${country:-?}"
  fi

  # 备用：ip-api.com
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

  # 国家代码回退表
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

# ---------- 同步网络时间（已修复 set -e 兼容性） ----------
sync_time() {
  if $DRY_RUN; then
    info "[dry-run] 将执行网络时间同步"
    return
  fi

  info "正在同步网络时间..."

  # ---- chrony ----
  if command -v chronyc &>/dev/null; then
    if chronyc makestep &>/dev/null; then
      success "chrony 时间同步完成"
      info "同步后时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
      return
    else
      warn "chronyc makestep 执行失败，尝试其他方式..."
    fi
  fi

  # ---- ntpdate ----
  if command -v ntpdate &>/dev/null; then
    if ntpdate -u pool.ntp.org &>/dev/null; then
      success "ntpdate 时间同步完成"
      info "同步后时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
      return
    else
      warn "ntpdate 执行失败，尝试其他方式..."
    fi
  fi

  # ---- systemd-timesyncd ----
  if command -v timedatectl &>/dev/null; then
    timedatectl set-ntp true 2>/dev/null || true
    # 修复：((i++)) 在 i=0 时返回 1，被 set -e 杀死
    # 改用 i=$((i + 1)) 避免此问题
    local i=0
    while [[ $i -lt 10 ]]; do
      sleep 1
      i=$((i + 1))
      if timedatectl show --property=NTPSynchronized 2>/dev/null | grep -q "yes"; then
        success "systemd-timesyncd 时间同步完成（等待 ${i} 秒）"
        info "同步后时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        return
      fi
    done
    warn "systemd-timesyncd 同步等待超时（10秒），时间可能仍有偏差"
    info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    return
  fi

  # ---- 尝试直接通过 HTTP 获取网络时间作参考 ----
  warn "未找到 chrony / ntpdate / systemd-timesyncd"
  info "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')（未同步，可能有偏差）"
}

# ---------- 输出校准结果 ----------
print_result() {
  local tz="$1"
  echo "" >&2
  echo -e "${BOLD}========== 时区校准结果 ==========${RESET}" >&2
  echo -e "  校准时区: ${GREEN}${tz}${RESET}" >&2
  if ! $DRY_RUN; then
    echo -e "  当前时间: ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}" >&2
    echo -e "  UTC  时间: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >&2
    if command -v timedatectl &>/dev/null; then
      echo "" >&2
      timedatectl status 2>/dev/null | grep -E "(Local time|Time zone|NTP|synchronized)" | sed 's/^/  /' >&2 || true
    fi
  fi
  echo -e "${BOLD}==================================${RESET}" >&2
}

# ---------- 主流程 ----------
main() {
  echo "" >&2
  echo -e "${BOLD}========== VPS 时区自动校准脚本 ==========${RESET}" >&2
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

  # 获取当前时区（每步都 || true 防止 set -e）
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

  sync_time
  print_result "$target_tz"
}

main "$@"
