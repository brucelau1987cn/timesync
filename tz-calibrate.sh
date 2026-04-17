#!/usr/bin/env bash
# =============================================================================
# VPS 时区自动校准脚本 v2.3
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine 等主流发行版
# 用法：bash tz-calibrate.sh [--dry-run] [--force TIMEZONE]
# =============================================================================

set -euo pipefail

# ---------- 意外退出捕获（调试用） ----------
trap 'echo -e "\033[0;31m[FATAL]\033[0m 脚本在第 $LINENO 行意外退出（退出码: $?）" >&2' EXIT

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
      trap - EXIT
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
# 从这里开始关闭 set -e，因为时间同步和结果展示中有太多可能返回非零的命令
# =========================================================================
sync_and_report() {
  set +e   # ★ 彻底关闭 errexit，防止任何意外退出
  set +o pipefail

  local target_tz="$1"
  local sync_ok=false
  local sync_method=""

  if $DRY_RUN; then
    info "[dry-run] 将执行网络时间同步"
  else
    info "正在同步网络时间..."

    # ---- chrony ----
    if command -v chronyc &>/dev/null; then
      info "检测到 chrony，尝试同步..."
      if chronyc makestep &>/dev/null; then
        sync_ok=true
        sync_method="chrony"
        success "chrony 时间同步完成"
      else
        warn "chronyc makestep 失败（chronyd 可能未运行），尝试其他方式..."
      fi
    fi

    # ---- ntpdate ----
    if ! $sync_ok && command -v ntpdate &>/dev/null; then
      info "检测到 ntpdate，尝试同步..."
      if ntpdate -u pool.ntp.org &>/dev/null; then
        sync_ok=true
        sync_method="ntpdate"
        success "ntpdate 时间同步完成"
      else
        warn "ntpdate 执行失败，尝试其他方式..."
      fi
    fi

    # ---- systemd-timesyncd ----
    if ! $sync_ok && command -v timedatectl &>/dev/null; then
      info "检测到 systemd-timesyncd，尝试同步..."
      timedatectl set-ntp true 2>/dev/null
      local i=1
      while [ "$i" -le 10 ]; do
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
        warn "systemd-timesyncd 同步等待超时（10秒），时间可能仍有偏差"
      fi
    fi

    # ---- 全部失败 ----
    if ! $sync_ok && [ -z "$sync_method" ]; then
      warn "未找到可用的时间同步工具（chrony / ntpdate / systemd-timesyncd）"
      warn "建议安装: apt install chrony 或 yum install chrony"
    fi
  fi

  # ---------- 输出校准结果 ----------
  echo "" >&2
  echo -e "${BOLD}============================================${RESET}" >&2
  echo -e "${BOLD}           时区校准结果汇总${RESET}" >&2
  echo -e "${BOLD}============================================${RESET}" >&2
  echo -e "  校准时区  : ${GREEN}${target_tz}${RESET}" >&2

  if ! $DRY_RUN; then
    echo -e "  本地时间  : ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${RESET}" >&2
    echo -e "  UTC 时间  : $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >&2

    if $sync_ok; then
      echo -e "  同步状态  : ${GREEN}✔ 已同步（${sync_method}）${RESET}" >&2
    else
      echo -e "  同步状态  : ${YELLOW}✘ 未同步或超时${RESET}" >&2
    fi

    # 获取网络参考时间（通过 HTTP 响应头）
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
      echo -e "  网络时间  : ${CYAN}${net_time}${RESET}" >&2
    fi

    # timedatectl 详情
    if command -v timedatectl &>/dev/null; then
      echo "" >&2
      echo -e "  ${BOLD}[ timedatectl 详情 ]${RESET}" >&2
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
  echo -e "${BOLD}========== VPS 时区自动校准脚本 v2.3 ==========${RESET}" >&2
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

  # 获取当前时区（每步 || true）
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

  # ★ 时间同步 + 结果展示（内部已关闭 set -e）
  sync_and_report "$target_tz"

  # 正常退出，清除 trap
  trap - EXIT
  exit 0
}

main "$@"
