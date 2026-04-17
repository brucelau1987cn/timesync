# ⏰ VPS 时区 & 时间自动校准脚本

自动根据 VPS 公网IP地址识别所属时区，配置系统时区并通过NTP同步时间，全程无需手动操作。

## 工作流程
### 阶段一：获取公网IP和时区
  curl -4 ip.sb → 获取公网IPv4
  curl ipinfo.io/{IP} → 获取时区/地区/运营商

### 阶段二：设置系统时区
  timedatectl set-timezone 或 ln -s 链接方式
  
### 阶段三：NTP时间同步
  自动检测/安装同步工具 → 选择就近NTP服务器同步
  
### 阶段四：输出结果汇总
  IP信息 / 时区信息 / 同步前后时间对比

## NTP工具处理逻辑
```
检测系统已安装的NTP工具
├── 有 chronyd   → 直接使用
├── 有 ntpdate   → 直接使用
├── 有 ntpd      → 直接使用
└── 都没有 → 自动安装
    ├── 安装 chrony    → 成功则使用
    ├── 安装 ntpdate   → 成功则使用
    ├── 安装 ntp       → 成功则使用
    └── 全部失败 → HTTP方式兜底
```

## 🚀 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/brucelau1987cn/tz-calibrate/main/tz-chronyd.sh)
```

## 后续常用命令

```bash
# 查看当前时间和时区状态
timedatectl

# 查看Chrony同步精度
chronyc tracking

# 查看NTP服务器连接状态
chronyc sources -v

# 手动强制同步一次
chronyc makestep
```
