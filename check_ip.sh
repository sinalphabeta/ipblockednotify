#!/bin/bash
#
# check_ip.sh —— 只检测当前出口 IP 是否疑似被墙，并通过 Telegram 通知结果。
#                （不做任何 IP 更换动作）
#
# 消息直接通过 Telegram 官方 API 发送：
#   https://api.telegram.org/bot<token>/sendMessage
#
# 用法示例：
#   bash check_ip.sh \
#       --machine-id      "xxx" \
#       --tg-bot-token    "7962046522:AAxxxxxxxx" \
#       --tg-chat-id      "-1003703734755"
#
# 参数说明（均可用 --key value 或 --key=value 两种写法）：
#   --machine-id      机器标识，默认取主机名 $(hostname)
#   --tg-bot-token    Telegram Bot Token（必填才会发送 TG）
#   --tg-chat-id      Telegram Chat ID  （必填才会发送 TG）
#   --tg-api-base     Telegram API 基地址，默认 https://api.telegram.org
#   --notify-mode     发送 TG 的时机：always（每次都发）| blocked（默认，仅状态变化时发：
#                     正常→被墙 发告警，被墙→恢复 发恢复通知，持续被墙期间不重复发）
#   --state-file      记录上次检测状态的文件，用于状态变化去重，
#                     默认 /var/run/ip_blocked_notify.state
#   -h, --help        显示帮助

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

set -o pipefail

# ---------- 默认值 ----------
MACHINE_ID="$(hostname)"
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_API_BASE="https://api.telegram.org"
NOTIFY_MODE="blocked"   # always | blocked
STATE_FILE="/var/run/ip_blocked_notify.state"

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --machine-id)    MACHINE_ID="$2"; shift 2 ;;
        --machine-id=*)  MACHINE_ID="${1#*=}"; shift ;;
        --tg-bot-token)    TG_BOT_TOKEN="$2"; shift 2 ;;
        --tg-bot-token=*)  TG_BOT_TOKEN="${1#*=}"; shift ;;
        --tg-chat-id)    TG_CHAT_ID="$2"; shift 2 ;;
        --tg-chat-id=*)  TG_CHAT_ID="${1#*=}"; shift ;;
        --tg-api-base)    TG_API_BASE="$2"; shift 2 ;;
        --tg-api-base=*)  TG_API_BASE="${1#*=}"; shift ;;
        --notify-mode)    NOTIFY_MODE="$2"; shift 2 ;;
        --notify-mode=*)  NOTIFY_MODE="${1#*=}"; shift ;;
        --state-file)    STATE_FILE="$2"; shift 2 ;;
        --state-file=*)  STATE_FILE="${1#*=}"; shift ;;
        -h|--help)       usage 0 ;;
        *) echo "未知参数: $1" >&2; usage 1 ;;
    esac
done

current_time=$(date "+%Y-%m-%d %H:%M:%S")

# ---------- 发送 Telegram 消息（直接调用官方 API） ----------
send_tg_message() {
    local message="$1"

    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        echo "[提示] 未提供 --tg-bot-token / --tg-chat-id，跳过 Telegram 通知。"
        return 0
    fi

    # 使用 --data-urlencode，text 中的换行/特殊字符都能安全传递
    curl -s -X POST "${TG_API_BASE}/bot${TG_BOT_TOKEN}/sendMessage" \
        --connect-timeout 5 --max-time 15 \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "disable_web_page_preview=true"
    echo
}

# ---------- 检测 IP 是否疑似被墙 ----------
# 返回值：0 = 疑似被墙，1 = 正常
check_ip_blocked() {
    local unicom_ips=(210.21.196.6 221.5.88.88 123.123.123.123)
    local mobile_ips=(221.131.143.69 211.138.180.2 218.201.96.130)
    local telecom_ips=(202.96.128.86 202.96.209.133 202.98.198.167)

    local unicom_ok=0 mobile_ok=0 telecom_ok=0
    local abnormal_count=0
    local ip

    local current_ipv4=""
    local default_blocked=1

    # 测联通
    for ip in "${unicom_ips[@]}"; do
        if ping -q -c 3 -W 10 -i 0.3 "$ip" >/dev/null 2>&1; then
            ((unicom_ok++)); echo "聯通 $ip 可達"
        else
            echo "聯通 $ip 不通"
        fi
    done

    # 测移动
    for ip in "${mobile_ips[@]}"; do
        if ping -q -c 3 -W 10 -i 0.3 "$ip" >/dev/null 2>&1; then
            ((mobile_ok++)); echo "移動 $ip 可達"
        else
            echo "移動 $ip 不通"
        fi
    done

    # 测电信
    for ip in "${telecom_ips[@]}"; do
        if ping -q -c 3 -W 10 -i 0.3 "$ip" >/dev/null 2>&1; then
            ((telecom_ok++)); echo "電信 $ip 可達"
        else
            echo "電信 $ip 不通"
        fi
    done

    # 哪一家完全不通，就算一个异常
    (( unicom_ok  == 0 )) && ((abnormal_count++))
    (( mobile_ok  == 0 )) && ((abnormal_count++))
    (( telecom_ok == 0 )) && ((abnormal_count++))

    echo "聯通可達: ${unicom_ok}/${#unicom_ips[@]} | 移動可達: ${mobile_ok}/${#mobile_ips[@]} | 電信可達: ${telecom_ok}/${#telecom_ips[@]}"

    # 取得目前本机出口 IPv4（仅用于通知展示）
    current_ipv4=$(curl -s -4 --connect-timeout 5 --max-time 8 https://api.ipify.org | tr -d '\r\n ')
    [[ "$current_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || current_ipv4="unknown"
    echo "目前出口 IPv4: $current_ipv4"

    TEST_MSG="聯通可達: ${unicom_ok}/${#unicom_ips[@]} | 移動可達: ${mobile_ok}/${#mobile_ips[@]} | 電信可達: ${telecom_ok}/${#telecom_ips[@]}"
    CURRENT_IPV4="$current_ipv4"

    # 判断：至少两家运营商完全不通 => 疑似被墙
    if (( abnormal_count >= 2 )); then
        BLOCK_REASON="IP被墙"
        echo "最終判斷：疑似已被牆"
        return 0
    fi

    echo "最終判斷：當前 IP 正常"
    return 1
}

# ---------- 状态文件读写（用于状态变化去重） ----------
read_prev_state() {
    [ -f "$STATE_FILE" ] && tr -d '\r\n ' < "$STATE_FILE" 2>/dev/null
}

save_state() {
    if ! echo "$1" > "$STATE_FILE" 2>/dev/null; then
        echo "[警告] 无法写入状态文件 $STATE_FILE，状态去重将失效（可用 --state-file 换一个可写路径）。" >&2
    fi
}

# ---------- 主逻辑（只检测 + 通知，不换 IP） ----------
prev_state="$(read_prev_state)"

if check_ip_blocked; then
    reason="${BLOCK_REASON:-IP被墙}"
    echo "[$current_time] 检测结果：疑似被墙（$reason），IP=${CURRENT_IPV4}"
    if [ "$NOTIFY_MODE" = "always" ] || [ "$prev_state" != "blocked" ]; then
        send_tg_message "$MACHINE_ID 当前IP (${CURRENT_IPV4}) $reason
檢測結果：$TEST_MSG
（仅检测，未更换IP）"
    else
        echo "仍处于被墙状态，此前已通知过，跳过重复通知。"
    fi
    save_state "blocked"
else
    echo "[$current_time] 检测结果：IP 正常，IP=${CURRENT_IPV4}"
    if [ "$prev_state" = "blocked" ]; then
        send_tg_message "$MACHINE_ID 当前IP (${CURRENT_IPV4}) 已恢复正常 ✅
檢測結果：$TEST_MSG"
    elif [ "$NOTIFY_MODE" = "always" ]; then
        send_tg_message "$MACHINE_ID 当前IP (${CURRENT_IPV4}) 检测正常
檢測結果：$TEST_MSG"
    fi
    save_state "ok"
fi
