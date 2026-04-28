# ⏰ VPS 时区 & 时间自动校准脚本

自动根据 VPS 公网 IP 地址识别所属时区，配置系统时区并通过 NTP 同步时间，全程无需手动操作。

[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://github.com/koalaman/shellcheck)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## ✨ 特性

- 🌐 **智能 IP 归属检测** — 优先从 ipinfo.io 获取时区，多来源自动兜底
- 🕐 **时区全覆盖** — 支持亚洲、欧洲、北美、南美、大洋洲、非洲主要时区
- 🛡️ **冲突自动处理** — 自动停止 systemd-timesyncd / ntpd 等冲突服务
- 🔧 **多工具支持** — chrony / ntpdate / ntpd 全自动检测安装
- 🌐 **HTTP 兜底** — NTP 不通时自动尝试 HTTP Date 头同步
- 📦 **多发行版支持** — Debian/Ubuntu、CentOS/RHEL、Alpine、Arch
- 🐚 **ShellCheck 零警告** — 通过严格静态检查，兼容 POSIX sed

## 🔄 工作流程

```
阶段一：获取公网IP和时区
  └─ 多个 IP 来源自动兜底 + 格式校验

阶段二：设置系统时区
  └─ timedatectl 优先，ln -s 链接兜底，失败时自动恢复旧链接

阶段三：NTP时间同步
  └─ 自动检测/安装 chrony → 就近 NTP 服务器同步

阶段四：输出结果汇总
  └─ IP信息 / 时区信息 / 同步前后时间对比
```

## 🔧 NTP 工具处理逻辑

```
检测系统已安装的 NTP 工具
├── 有 chronyd  → 直接使用（推荐）
├── 有 ntpdate  → 单次同步
├── 有 ntpd     → 配置并启动
└── 都没有 → 自动安装
    ├── 安装 chrony   → 成功则使用
    ├── 安装 ntpdate  → 成功则使用
    ├── 安装 ntp      → 成功则使用
    └── 全部失败 → HTTP Date 头兜底同步
```

## 🚀 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash
```

> 需要 root 权限运行

## 🛠️ 后续常用命令

```bash
# 查看当前时间和时区状态
timedatectl

# 查看 Chrony 同步精度
chronyc tracking

# 查看 NTP 服务器连接状态
chronyc sources -v

# 手动强制同步一次（立即生效）
chronyc makestep

# 查看硬件时钟
hwclock --show
```

## 📋 支持的时区（部分）

| 地区 | 时区 | 优先 NTP 服务器 |
|------|------|-----------------|
| 🇨🇳 中国大陆 | Asia/Shanghai | ntp.aliyun.com / ntp.tencent.com |
| 🇭🇰 香港 | Asia/Hong_Kong | hk.pool.ntp.org |
| 🇯🇵 日本 | Asia/Tokyo | jp.pool.ntp.org |
| 🇰🇷 韩国 | Asia/Seoul | kr.pool.ntp.org |
| 🇸🇬 新加坡 | Asia/Singapore | sg.pool.ntp.org |
| 🇹🇼 台湾 | Asia/Taipei | tw.pool.ntp.org |
| 🇮🇳 印度 | Asia/Kolkata | in.pool.ntp.org |
| 🇬🇧 英国 | Europe/London | uk.pool.ntp.org |
| 🇩🇪 德国/法国 | Europe/Berlin | de.pool.ntp.org |
| 🇷🇺 俄罗斯 | Europe/Moscow | ru.pool.ntp.org |
| 🇺🇸 美国 | America/New_York 等 | us.pool.ntp.org |
| 🇨🇦 加拿大 | America/Toronto / Vancouver | ca.pool.ntp.org |
| 🇧🇷 巴西 | America/Sao_Paulo | br.pool.ntp.org |
| 🇦🇺 澳大利亚 | Australia/* | oceania.pool.ntp.org |
| 🌐 其他 | - | pool.ntp.org + Google/Cloudflare |

## 🐛 已知问题

- IPv6-only 环境暂不支持
- 非 root 用户需配合 `sudo` 使用

## 📜 更新日志

### [1.1.0] — 2026-04-28

- 🐛 **修复**: 中国 VPS 上 HTTP 兜底因 `set -euo pipefail` 导致脚本意外退出
- 🐛 **修复**: Alpine Linux / BusyBox 下 `grep -oP` 不兼容，JSON 解析 fallback 失效
- 🛡️ **增强**: `/etc/localtime` 链接失败时自动恢复旧链接，避免时区丢失
- 🧹 **优化**: 提取 `fetch_http_date()` 函数消除 40 行重复代码
- 🔍 **检查**: 主函数增加 `curl` 依赖预检，缺失时自动安装
- 🧪 **质量**: 通过 ShellCheck 静态检查，零警告

