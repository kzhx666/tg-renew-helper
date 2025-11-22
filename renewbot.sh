#!/usr/bin/env bash
# Telegram VPS 续期提醒 + 一键续期 + 在线修改URL + 自动检测续费页面是否可访问
# 依赖: curl, grep, sed, jq
# 使用: bash renewbot.sh

set -e

CONFIG_FILE="/root/renewbot_config.json"
LOG_FILE="/root/renewbot.log"

# ==================== 配置初始化 ====================
init_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
{
  "TG_BOT_TOKEN": "YOUR_BOT_TOKEN",
  "TG_CHAT_ID": "YOUR_CHAT_ID",
  "RENEW_URL": "https://example.com/renew",
  "REMIND_DAYS": 1
}
EOF
  fi
}

load_config() {
  TG_BOT_TOKEN=$(jq -r '.TG_BOT_TOKEN' $CONFIG_FILE)
  TG_CHAT_ID=$(jq -r '.TG_CHAT_ID' $CONFIG_FILE)
  RENEW_URL=$(jq -r '.RENEW_URL' $CONFIG_FILE)
  REMIND_DAYS=$(jq -r '.REMIND_DAYS' $CONFIG_FILE)
}

# ==================== Telegram 消息发送 ====================
send_tg() {
  local TEXT="$1"
  curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" -d text="$TEXT" -d parse_mode="HTML" >/dev/null
}

send_with_button() {
  local TEXT="$1"
  local URL="$2"
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
   -d chat_id="$TG_CHAT_ID" \
   -d parse_mode="HTML" \
   -d text="$TEXT" \
   -d reply_markup="{\"inline_keyboard\":[[{\"text\":\"立即续期\",\"url\":\"$URL\"}]]}" >/dev/null
}

# ==================== 网页可访问性检测 ====================
check_page() {
  if curl -Is "$RENEW_URL" | head -1 | grep -q "200"; then
    echo "$(date) OK: $RENEW_URL 可访问" >> $LOG_FILE
  else
    send_tg "⚠️ <b>续期页面无法访问</b>\n$RENEW_URL"
    echo "$(date) ERROR: $RENEW_URL 无法访问" >> $LOG_FILE
  fi
}

# ==================== Telegram 命令处理 ====================
handle_commands() {
  OFFSET=0
  NEXT=""
  while true; do
    UPDATES=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?offset=$OFFSET")
    RESULT_COUNT=$(echo "$UPDATES" | jq ".result | length")

    if [ "$RESULT_COUNT" -gt 0 ]; then
      for ((i=0; i<$RESULT_COUNT; i++)); do
        UPDATE_ID=$(echo "$UPDATES" | jq ".result[$i].update_id")
        MESSAGE=$(echo "$UPDATES" | jq -r ".result[$i].message.text")

        OFFSET=$((UPDATE_ID+1))

        case "$MESSAGE" in
          /seturl*)
            NEW_URL=$(echo "$MESSAGE" | cut -d ' ' -f2)
            if [[ -z "$NEW_URL" ]]; then
              send_tg "用法: /seturl https://example.com/renew"
            else
              jq --arg u "$NEW_URL" '.RENEW_URL = $u' $CONFIG_FILE > ${CONFIG_FILE}.tmp && mv ${CONFIG_FILE}.tmp $CONFIG_FILE
              load_config
              send_tg "🔧 已更新续期链接:\n<b>$RENEW_URL</b>"
            fi
          ;;

          /status)
            send_tg "当前续期URL:\n<b>$RENEW_URL</b>"
          ;;

          *)
            send_tg "可用指令:\n/seturl URL  修改续期链接\n/status 查看当前设置"
          ;;
        esac
      done
    fi
    sleep 2
  done
}

# ==================== 自动提醒 ====================
check_notify() {
  while true; do
    send_with_button "🔔 你的 VPS 续期提醒：\n请点击按钮续期" "$RENEW_URL"
    sleep 86400
  done
}

# ==================== 主函数 ====================
main() {
  init_config
  load_config
  send_tg "🔧 续期提醒机器人已启动"

  check_notify &
  handle_commands &

  while true; do
    check_page
    sleep 3600
  done
}

main
