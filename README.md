# ip_blocked_notify

检测服务器出口 IP 是否疑似被墙（GFW 封锁），并通过 Telegram Bot 通知。适合部署在境外 VPS 上，IP 一被墙就能第一时间收到提醒。**只做检测，不做任何更换 IP 的操作。**

## 检测原理

分别 ping 中国联通、移动、电信各 3 个国内 IP（每个 ping 3 次）：

- 某家运营商的 3 个 IP **全部不通** → 记一个"异常"
- **至少两家运营商异常** → 判定为"疑似被墙"，发送 Telegram 通知

同时通过 `api.ipify.org` 获取当前出口 IPv4，附在通知消息里。

## 文件说明

| 文件 | 作用 |
|------|------|
| `check_ip.sh` | 检测脚本本体，可单独手动执行 |
| `install.sh` | 安装脚本：把 `check_ip.sh` 部署到 `/opt/ip_blocked_notify/` 并配置 cron 定时任务 |

## 一键安装（需要 root，仅支持 Linux）

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sinalphabeta/ipblockednotify/main/install.sh) \
    --machine-id   "xxx" \
    --tg-bot-token "7962046522:AAxxxxxxxx" \
    --tg-chat-id   "-1003703734755"
```

传给 `install.sh` 的所有参数会原样传递给 `check_ip.sh`。也可以先 `git clone` 本仓库再在仓库目录里执行 `sudo bash install.sh <参数>`（有本地 `check_ip.sh` 时优先使用本地文件，否则自动从 GitHub raw 下载）。

系统缺少 `cron` 或 `flock` 时，安装脚本会尝试用包管理器（apt / yum / dnf / apk / pacman / zypper）自动安装并启动服务。

安装后自动完成以下配置：

- `check_ip.sh` 放到 `/opt/ip_blocked_notify/` 并赋予执行权限
- crontab 每分钟执行一次检测（参数直接写在 cron 命令里），输出追加到 `/var/log/ip_blocked_notify.log`
- crontab 每天 0 点自动清空该日志文件
- cron 命令通过 `flock` 非阻塞锁执行：单次检测耗时可能超过一分钟（最坏情况 9 个 IP 全超时），上一轮没跑完时新一轮直接跳过，保证同一时间只有一个实例在运行

## 参数说明

| 参数 | 说明 |
|------|------|
| `--machine-id` | 机器标识，用于区分通知来自哪台机器，默认取主机名 |
| `--tg-bot-token` | Telegram Bot Token（不填则只写日志、不发通知） |
| `--tg-chat-id` | Telegram Chat ID |
| `--tg-api-base` | Telegram API 基地址，默认 `https://api.telegram.org`，可换成反代地址 |
| `--notify-mode` | `blocked`（默认，仅状态变化时通知）或 `always`（每次检测都通知） |
| `--state-file` | 记录上次检测状态的文件，默认 `/var/run/ip_blocked_notify.state` |

## 通知策略（默认 blocked 模式）

只在**状态发生变化**时发送 Telegram 通知，避免被墙期间每分钟刷屏：

- 正常 → 被墙：发送告警
- 被墙 → 恢复：发送恢复通知 ✅
- 持续被墙 / 持续正常：不发消息（日志仍每分钟记录）

上次状态记录在 `--state-file` 指定的文件中。默认路径 `/var/run` 在重启后会清空，重启后若仍处于被墙状态会重新发一次告警（属于预期行为）。`always` 模式则不做去重，每次检测都发。

## 常用操作

```bash
# 查看实时日志
tail -f /var/log/ip_blocked_notify.log

# 手动执行一次检测（参数换成你自己的，或直接从 crontab -l 里复制完整命令）
sudo /opt/ip_blocked_notify/check_ip.sh --machine-id "xxx" --tg-bot-token "xxx" --tg-chat-id "xxx"

# 查看已安装的定时任务
sudo crontab -l | grep ip_blocked_notify

# 卸载（删除 cron 条目和 /opt/ip_blocked_notify/，日志文件保留）
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sinalphabeta/ipblockednotify/main/install.sh) --uninstall
```

## 注意事项

- `check_ip.sh` 使用 Linux 版 `ping` 的参数（`-W`、`-i 0.3`），不能在 macOS 上直接运行。
