#!/bin/bash
#
# install.sh —— 安装 IP 被墙检测定时任务（Linux）
#
# 一键安装（从 GitHub 执行）：
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/sinalphabeta/ipblockednotify/main/install.sh) \
#       --machine-id      "xxx" \
#       --tg-bot-token    "7962046522:AAxxxxxxxx" \
#       --tg-chat-id      "-1003703734755"
#
#   所有参数会原样传递给 check_ip.sh。
#
# 安装后效果：
#   1. check_ip.sh 放到 /opt/ip_blocked_notify/ 并赋予执行权限
#      （本地目录有 check_ip.sh 就用本地的，否则从 GitHub raw 下载）
#   2. crontab 每分钟执行一次检测（带参数），日志追加到 /var/log/ip_blocked_notify.log
#   3. crontab 每天 0 点清空该日志文件
#   4. 定时任务通过 flock 加锁，保证同一时间只有一个检测实例在运行
#
# 卸载：
#   sudo bash install.sh --uninstall
#

set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/sinalphabeta/ipblockednotify/main"
INSTALL_DIR="/opt/ip_blocked_notify"
CHECK_SCRIPT="$INSTALL_DIR/check_ip.sh"
LOG_FILE="/var/log/ip_blocked_notify.log"
LOCK_FILE="/var/run/ip_blocked_notify.lock"
CRON_MARKER="# ip_blocked_notify"

# ---------- 前置检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限（写入 /opt、/var/log 和 root crontab），请用 sudo 执行。" >&2
    exit 1
fi

# ---------- 卸载 ----------
if [ "${1:-}" = "--uninstall" ]; then
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmp_cron" || true
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    rm -rf "$INSTALL_DIR"
    rm -f "$LOCK_FILE"
    echo "已卸载：crontab 条目和 $INSTALL_DIR 已删除。"
    echo "日志文件 $LOG_FILE 保留，如需删除请手动执行：rm -f $LOG_FILE"
    exit 0
fi

if ! command -v flock >/dev/null 2>&1; then
    echo "错误：未找到 flock 命令（通常在 util-linux 包中），请先安装。" >&2
    exit 1
fi

if ! command -v crontab >/dev/null 2>&1; then
    echo "错误：未找到 crontab 命令，请先安装 cron（如 cronie / cron 包）。" >&2
    exit 1
fi

# 提醒：没给 TG 参数时脚本只会写日志，不会发通知
case " $* " in
    *" --tg-bot-token"*) : ;;
    *) echo "[提示] 未提供 --tg-bot-token / --tg-chat-id，检测结果只写日志，不会发送 Telegram 通知。" ;;
esac

# ---------- 安装 check_ip.sh ----------
mkdir -p "$INSTALL_DIR"

SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/check_ip.sh" ]; then
    echo "使用本地 check_ip.sh：$SRC_DIR/check_ip.sh"
    cp "$SRC_DIR/check_ip.sh" "$CHECK_SCRIPT"
else
    echo "本地未找到 check_ip.sh，从 GitHub 下载..."
    curl -fsSL "$REPO_RAW_BASE/check_ip.sh" -o "$CHECK_SCRIPT"
fi
chmod +x "$CHECK_SCRIPT"

touch "$LOG_FILE"

# ---------- 构造 cron 命令 ----------
# 把每个参数用双引号包起来并转义 \ " $ `，保证 cron 的 /bin/sh 也能正确解析；
# cron 里 % 是特殊字符（表示换行），最后统一转义成 \%。
sh_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '"%s"' "$s"
}

CRON_CMD="flock -n $LOCK_FILE $CHECK_SCRIPT"
for arg in "$@"; do
    CRON_CMD+=" $(sh_quote "$arg")"
done
CRON_CMD+=" >> $LOG_FILE 2>&1"
CRON_CMD="${CRON_CMD//%/\\%}"

# ---------- 写入 crontab（幂等：先清掉旧条目再加） ----------
tmp_cron="$(mktemp)"
crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" > "$tmp_cron" || true
{
    echo "* * * * * $CRON_CMD $CRON_MARKER"
    echo "0 0 * * * truncate -s 0 $LOG_FILE $CRON_MARKER"
} >> "$tmp_cron"
crontab "$tmp_cron"
rm -f "$tmp_cron"

echo "安装完成！"
echo "  检测脚本：  $CHECK_SCRIPT"
echo "  定时任务：  每分钟检测一次（flock 防止并发），每天 0 点清空日志"
echo "  日志文件：  $LOG_FILE"
echo
echo "查看定时任务：sudo crontab -l | grep ip_blocked_notify"
echo "查看实时日志：tail -f $LOG_FILE"
echo "卸载：        sudo bash <(curl -fsSL $REPO_RAW_BASE/install.sh) --uninstall"
