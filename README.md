# ⏰ timesync — VPS 时区与时间自动校准脚本

[![Shell CI](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml/badge.svg)](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml) [![Release](https://img.shields.io/github/v/release/brucelau1987cn/timesync?color=blue&label=version)](https://github.com/brucelau1987cn/timesync/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个面向 VPS 的一键时区与时间校准脚本：根据公网 IP 自动识别时区，配置系统时区，并优先使用 chrony 做时间同步。支持 Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等常见 Linux 发行版。

## 快速开始

### 一键执行（需要 root 权限）
```bash
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash
```

### 或先下载审阅再运行
```bash
curl -fsSL -o timesync.sh https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh
bash timesync.sh
```

## 适用场景

- 新 VPS 初始化后自动设置正确时区与系统时间
- 远程 SSH / 云面板 / 自动化脚本中无人值守执行
- Debian 13 等新系统上自动处理 chrony runtime 目录与陈旧 pid 问题
- NTP 不通时自动降级为 HTTP Date 头兜底同步

## 主要特性

- 🌐 **智能时区检测**：通过公网 IPv4 自动识别地理位置与时区，多来源兜底。
- 🕐 **自动时区配置**：优先使用 `timedatectl`，失败时使用 `/etc/localtime` 链接方式并带回滚保护。
- 🔧 **多 NTP 工具支持**：优先使用 chrony，兼容 ntpdate / ntpd；缺失时自动安装。
- 🛡️ **冲突服务处理**：自动处理 systemd-timesyncd / ntpd 等可能冲突的服务。
- ✅ **Debian 13 兼容**：启动 chrony 前修复 `/run/chrony`、`/var/lib/chrony`、`/var/log/chrony` 权限并删除 stale pid。
- 🤖 **非交互安全**：支持 `curl | bash`、SSH/CI/cron 等无 TTY 场景，终端命令自动跳过。
- 🧪 **CI 保障**：GitHub Actions 自动运行 `bash -n` 和 ShellCheck。

## 运行流程

1. 获取公网 IP 与时区信息。
2. 根据识别结果配置系统时区。
3. 检测或安装 chrony / ntpdate / ntpd。
4. 写入同步配置并启动时间同步服务。
5. 等待 chrony daemon 可响应后执行 `chronyc -a makestep`。
6. 输出同步源、tracking 状态和最终时间信息。

## 非交互环境说明

脚本已兼容无 TTY / 无 `TERM` 的环境，例如 SSH 远程命令、CI、cron、自动化面板等。

```bash
# 推荐：直接执行即可
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash

# 如果你的运行器强制要求 TERM，可显式设置
TERM=xterm bash timesync.sh
```

内部已对 `clear`、`tput`、`stty`、交互提示等终端专用操作提供 safe wrapper，避免非交互环境下提前退出。

## 常用验证命令

```bash
# 查看当前时区与 NTP 总体状态
timedatectl

# 查看 chrony 同步状态
chronyc tracking

# 查看 chrony 同步源
chronyc sources -v

# 手动强制同步一次
chronyc -a makestep

# 查看 chrony 日志
journalctl -u chrony -n 200 --no-pager
```

## 常见问题

### `chronyc` 提示 `506 Cannot talk to daemon`

通常表示 chronyd 没有正常运行，常见原因包括：

- `/run/chrony` 不存在或权限不正确；
- `/var/lib/chrony`、`/var/log/chrony` 归属不匹配；
- 存在陈旧的 `/run/chrony/chronyd.pid`；
- 上一次 chronyd 异常退出，systemd 中仍有残留进程；
- chrony 配置写入后 daemon 尚未完全 ready。

脚本已内置处理：创建目录、修正 `_chrony` 权限、删除 stale pid、重启 chrony、等待 daemon ready，再执行 `makestep`。若仍失败，请执行：

```bash
systemctl status chrony --no-pager -l
journalctl -u chrony -n 200 --no-pager
```

### 脚本在 SSH/面板/cron 中无输出或提前退出

请确认使用的是最新版本（v1.2.4+）。该版本已修复无 `TERM` 环境下 `clear` 等终端命令导致脚本提前退出的问题。

## 变更日志（摘录）

- **v1.2.4**：非交互环境安全加固；新增 safe wrapper；整理 README；增加 GitHub Actions CI。
- **v1.2.3**：修复 Debian 13 chrony runtime-dir / stale pid 导致 `chronyc makestep` 失败。
- **v1.2.0**：修复 chrony/ntp 安装检测、ipinfo JSON 解析与 HTTP 兜底健壮性问题。

完整版本见：[GitHub Releases](https://github.com/brucelau1987cn/timesync/releases)

## 贡献与质量保障

- 欢迎提交 PR 修复兼容性问题、补充测试或改进文档。
- PR 会自动运行 Shell CI：`bash -n timesync.sh` + ShellCheck。

## 安全提示

不要在 Issue、PR、聊天或提交记录中暴露 GitHub token、服务器密码、私钥等敏感凭据。若已暴露，请立即撤销/rotate。

## License

MIT
