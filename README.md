# ⏰ timesync — VPS 时区与时间自动校准脚本

[![Shell CI](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml/badge.svg)](https://github.com/brucelau1987cn/timesync/actions/workflows/shell-ci.yml) [![Release](https://img.shields.io/github/v/release/brucelau1987cn/timesync?color=blue&label=version)](https://github.com/brucelau1987cn/timesync/releases) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个面向 VPS 的一键时区与时间校准脚本：根据公网 IP 自动识别时区，配置系统时区并优先使用 chrony 做时间同步，兼容常见 Linux 发行版（Debian/Ubuntu、CentOS/RHEL、Alpine、Arch）。

简要说明
- 目标：尽可能在无人值守场景（自动化面板、SSH 一键脚本、云面板）下自动完成时区+时间校准。
- 设计原则：安全（非交互友好）、跨发行版、可重复运行、易于排查。

快速开始
```bash
# 推荐（安全、最新）：从主分支获取并执行
curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh | bash

# 或者先下载、审阅再运行
curl -fsSL -o timesync.sh https://raw.githubusercontent.com/brucelau1987cn/timesync/main/timesync.sh
bash timesync.sh
```
> 说明：脚本需要 root 权限（sudo 或 root）以写入时区、重启服务和安装依赖。

非交互/自动化运行
- 本仓库已对无 TTY（无 TERM）场景做了保护：终端专用命令（如 clear、tput、stty）会在非交互时自动跳过，避免因 `TERM environment variable not set` 导致 `set -euo pipefail` 提前退出。
- 建议在某些严格环境显式设置 TERM：`TERM=xterm bash timesync.sh`（通常不必）

主要特性
- 智能 IP → 时区检测（多来源兜底）
- 自动停用冲突服务（systemd-timesyncd / ntpd）
- 优先使用 chrony（若缺失则自动安装）；支持 ntpdate/ntpd 作为备选
- Debian 13 chrony 启动兼容修复（确保 runtime/state/log 目录并删除陈旧 pid）
- 非交互安全包装（safe_clear、safe_tput、safe_stty）
- CI 检查：bash -n + ShellCheck

工作流程（高层）
1. 获取公网 IP 与地理/时区信息
2. 配置系统时区（timedatectl 优先，失败退到手动链接）
3. 检测/安装 NTP 工具并启动（首选 chrony）
4. 等待 chrony 稳定，执行 `chronyc -a makestep`（若可用）
5. 输出验证信息（chronyc tracking / chronyc sources / journalctl）

常用命令（排查与验证）
- 查看时区与 NTP 总体状态：`timedatectl`
- 查看 chrony 同步状态：`chronyc tracking`
- 查看 chrony 源：`chronyc sources -v`
- 强制立即同步（危险——会步进系统时钟）：`chronyc -a makestep`
- 查看 chrony 日志：`journalctl -u chrony -n 200 --no-pager`

常见问题与处理
- 问：执行后出现 `506 Cannot talk to daemon` 或 `chronyd exiting`？
  - 原因：chronyd 进程未能在干净的 runtime 环境下创建控制 socket（/run/chrony 缺失或权限不当）、或有残留进程/陈旧 pid 导致启动失败。
  - 处理（已内置在脚本）：确保 `/run/chrony`、`/var/lib/chrony`、`/var/log/chrony` 存在并归属 `_chrony`（若存在），删除 `/run/chrony/chronyd.pid`，重启 chrony，并等待 chronyc 可用后再执行 makestep。
  - 若仍失败：查看 `journalctl -u chrony -n 200` 以获取详细日志并贴出来给我，我帮你分析。

变更日志（摘录）
- v1.2.4 — 非交互安全加固、增加 safe_* 包装函数、README 整理、添加 CI workflow
- v1.2.3 — 修复 Debian 13 chrony runtime-dir / stale pid 导致 `chronyc makestep` 失败
- v1.2.0 — 多项安装与解析健壮性修复

贡献
- 欢迎提 PR：修复 bug、改进兼容性、补充测试或增强文档。
- 本仓库已开启 CI（ShellCheck / bash -n），PR 提交后会自动检查。

安全提示
- 请不要在公共聊天或仓库提交敏感凭据（GitHub token、服务器密码、私钥）。若曾在对话中泄露，请尽快撤销/rotate。

License
- MIT

---
如果你希望我用更简洁的两页格式（快速上手 + 进阶排查），或把 README 翻译成英文版 README.en.md，我可以再做一次精简与新增英文版。告诉我你偏好哪种风格（简洁版 / 详细版 + 英文）。
