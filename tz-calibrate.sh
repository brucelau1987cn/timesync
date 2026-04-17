#!/usr/bin/env bash
# =============================================================================
# VPS 时区自动校准脚本 v2.4
# 根据公网 IP 归属地自动识别所在时区并完成校准
# 支持：Debian/Ubuntu、CentOS/RHEL、Alpine 等主流发行版
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
# 关闭 set -e，进入时间同步 + 报告阶段
# =========================================================================
sync_and_report() {
  set +e
  set +o pipefail

  local target_tz="$1"
  local sync_ok=false
  local sync_method=""

  if $DRY_RUN; then
    info "[dry-run] 将执行网络时间同步"
  else
    info "正在同步网络时间..."
    local tried_any=false

    # ---- 1. chrony（已安装） ----
    if command -v chronyc &>/dev/null; then
      tried_any=true
      info "检测到 chrony，尝试同步..."
      # 确保 chronyd 在运行
      systemctl start chronyd 2>/dev/null || service chronyd start 2>/dev/null || true
      sleep 1
      if chronyc makestep &>/dev/null; then
        sync_ok=true
        sync_method="chrony"
        success "chrony 时间同步完成"
      else
        warn "chronyc makestep 失败"
      fi
    fi

    # ---- 2. ntpdate（已安装） ----
    if ! $sync_ok && command -v ntpdate &>/dev/null; then
      tried_any=true
      info "检测到 ntpdate，尝试同步..."
      if ntpdate -u pool.ntp.org &>/dev/null; then
        sync_ok=true
        sync_method="ntpdate"
        success "ntpdate 时间同步完成"
      else
        warn "ntpdate 执行失败"
      fi
    fi

    # ---- 3. systemd-timesyncd（检查是否真正可用） ----
    if ! $sync_ok && command -v timedatectl &>/dev/null; then
      # 检查 NTP service 是否为 n/a（表示没有 NTP 后端）
      local ntp_svc
      ntp_svc=$(timedatectl status 2>/dev/null | grep -i "NTP service" || true)
      if echo "$ntp_svc" | grep -qi "n/a"; then
        warn "systemd-timesyncd 未安装（NTP service: n/a）"
      else
        tried_any=true
        info "检测到 systemd-timesyncd，尝试同步..."
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
    fi

    # ---- 4. 没有可用 NTP 工具 → 自动安装 chrony ----
    if ! $sync_ok; then
      info "没有可用的 NTP 同步工具，尝试自动安装 chrony..."
      local install_ok=false

      if command -v apt-get &>/dev/null; then
        info "使用 apt-get 安装 chrony..."
        apt-get update -qq 2>/dev/null
        if apt-get install -y -qq chrony 2>/dev/null; then
          install_ok=true
        fi
      elif command -v yum &>/dev/null; then
        info "使用 yum 安装 chrony..."
        if yum install -y -q chrony 2>/dev/null; then
          install_ok=true
        fi
      elif command -v dnf &>/dev/null; then
        info "使用 dnf 安装 chrony..."
        if dnf install -y -q chrony 2>/dev/null; then
          install_ok=true
        fi
      elif command -v apk &>/dev/null; then
        info "使用 apk 安装 chrony..."
        if apk add --quiet chrony 2>/dev/null; then
          install_ok=true
        fi
      elif command -v pacman &>/dev/null; then
        info "使用 pacman 安装 chrony..."
        if pacman -Sy --noconfirm chrony 2>/dev/null; then
          install_ok=true
        fi
      fi

      if $install_ok && command -v chronyc &>/dev/null; then
        success "chrony 安装成功"
        # 启动 chronyd
        systemctl enable --now chronyd 2>/dev/null \
          || service chronyd start 2>/dev/null \
          || chronyd 2>/dev/null \
          || true
        info "等待 chrony 同步..."
        sleep 3
        if chronyc makestep &>/dev/null; then
          sync_ok=true
          sync_method="chrony（自动安装）"
          success "chrony 时间同步完成"
        else
          warn "chrony 已安装但 makestep 失败，尝试等待自动同步..."
          sleep 5
          # 检查偏差
          local offset
          offset=$(chronyc tracking 2>/dev/null | grep "System time" | grep -oP '[\d.]+' | head -1 || echo "")
          if [ -n "$offset" ]; then
            info "当前时钟偏差: ${offset} 秒"
            sync_ok=true
            sync_method="chrony（自动安装，偏差 ${offset}s）"
          fi
        fi
      else
        warn "chrony 自动安装失败"
      fi
    fi

    # ---- 5. 终极回退：用 HTTP 响应头 date -s 强制校时 ----
    if ! $sync_ok; then
      info "尝试通过 HTTP 响应头校准系统时间（最后手段）..."
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
          # 某些 busybox 的 date -s 格式不同，尝试转换
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

    # 获取网络参考时间用于对比
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
      # 计算偏差秒数
      local net_epoch local_epoch diff_sec=""
      net_epoch=$(date -d "$net_time" +%s 2>/dev/null || true)
      local_epoch=$(date +%s 2>/dev/null || true)
      if [ -n "$net_epoch" ] && [ -n "$local_epoch" ]; then
        diff_sec=$((local_epoch - net_epoch))
        # 取绝对值
        if [ "$diff_sec" -lt 0 ] 2>/dev/null; then
          diff_sec=$(( -diff_sec ))
        fi
      fi

      echo -e "  网络参考  : ${CYAN}${net_time}${RESET}" >&2
      if [ -n "$diff_sec" ]; then
        if [ "$diff_sec" -le 2 ]; then
          echo -e "  时间偏差  : ${GREEN}≤ ${diff_sec} 秒（精准）${RESET}" >&2
        elif [ "$diff_sec" -le 10 ]; then
          echo -e "  时间偏差  : ${YELLOW}约 ${diff_sec} 秒（可接受）${RESET}" >&2
        else
          echo -e "  时间偏差  : ${RED}约 ${diff_sec} 秒（偏差较大）${RESET}" >&2
        fi
      fi
    fi

    echo -e "${BOLD}--------------------------------------------${RESET}" >&2

    # timedatectl 详情
    if command -v timedatectl &>/dev/null; then
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
  echo -e "${BOLD}========== VPS 时区自动校准脚本 v2.4 ==========${RESET}" >&2
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
