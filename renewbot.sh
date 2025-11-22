#!/usr/bin/env bash
# Telegram 多 VPS 管理 + 续期提醒 + Inline Keyboard
# 依赖: curl, jq
# 保存为 /root/renewbot.sh
# 使用: bash renewbot.sh

set -e

CONFIG_FILE="/root/renewbot_config.json"
VPS_FILE="/root/renewbot_vps.json"
LOG_FILE="/root/renewbot.log"

# ==================== 初始化配置 ====================
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
{
  "TG_BOT_TOKEN": "YOUR_BOT_TOKEN",
  "TG_CHAT_ID": "YOUR_CHAT_ID"
}
EOF
    fi

    if [ ! -f "$VPS_FILE" ]; then
        echo "[]" > "$VPS_FILE"
    fi
}

load_config() {
    TG_BOT_TOKEN=$(jq -r '.TG_BOT_TOKEN' "$CONFIG_FILE")
    TG_CHAT_ID=$(jq -r '.TG_CHAT_ID' "$CONFIG_FILE")
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

# ==================== VPS 管理 ====================
add_vps() {
    local NAME="$1"
    local URL="$2"
    local DATE="$3"
    jq --arg n "$NAME" --arg u "$URL" --arg e "$DATE" '. += [{"name":$n,"url":$u,"expire":$e}]' "$VPS_FILE" > ${VPS_FILE}.tmp && mv ${VPS_FILE}.tmp "$VPS_FILE"
    send_tg "✔ 已添加 VPS：$NAME"
}

set_vps_url() {
    local NAME="$1"
    local URL="$2"
    jq --arg n "$NAME" --arg u "$URL" 'map(if .name==$n then .url=$u else . end)' "$VPS_FILE" > ${VPS_FILE}.tmp && mv ${VPS_FILE}.tmp "$VPS_FILE"
    send_tg "🔧 VPS $NAME 链接已更新为：$URL"
}

set_vps_date() {
    local NAME="$1"
    local DATE="$2"
    jq --arg n "$NAME" --arg e "$DATE" 'map(if .name==$n then .expire=$e else . end)' "$VPS_FILE" > ${VPS_FILE}.tmp && mv ${VPS_FILE}.tmp "$VPS_FILE"
    send_tg "📅 VPS $NAME 到期日期已更新为：$DATE"
}

del_vps() {
    local NAME="$1"
    jq --arg n "$NAME" 'map(select(.name != $n))' "$VPS_FILE" > ${VPS_FILE}.tmp && mv ${VPS_FILE}.tmp "$VPS_FILE"
    send_tg "❌ VPS $NAME 已删除"
}

list_vps() {
    local MSG="📋 当前 VPS 列表：\n\n"
    local COUNT=$(jq 'length' "$VPS_FILE")
    if [ "$COUNT" -eq 0 ]; then
        MSG+="无 VPS"
    else
        for i in $(seq 0 $((COUNT-1))); do
            local NAME=$(jq -r ".[$i].name" "$VPS_FILE")
            local URL=$(jq -r ".[$i].url" "$VPS_FILE")
            local EXPIRE=$(jq -r ".[$i].expire" "$VPS_FILE")
            local LEFT=$(( ( $(date -d "$EXPIRE" +%s) - $(date +%s) ) / 86400 ))
            MSG+="名称：<b>$NAME</b>\n到期：$EXPIRE\n剩余：$LEFT 天\n🔗 $URL\n\n"
        done
    fi
    send_tg "$MSG"
}

# ==================== 检测到期提醒 ====================
check_notify() {
    while true; do
        local COUNT=$(jq 'length' "$VPS_FILE")
        for i in $(seq 0 $((COUNT-1))); do
            local NAME=$(jq -r ".[$i].name" "$VPS_FILE")
            local URL=$(jq -r ".[$i].url" "$VPS_FILE")
            local EXPIRE=$(jq -r ".[$i].expire" "$VPS_FILE")
            local LEFT=$(( ( $(date -d "$EXPIRE" +%s) - $(date +%s) ) / 86400 ))
            if [ "$LEFT" -eq 1 ]; then
                send_with_button "⚠️ VPS <b>$NAME</b> 明天到期！\n请点击按钮续期" "$URL"
            fi
        done
        sleep 3600  # 每小时检查一次
    done
}

# ==================== 网页可访问性检测 ====================
check_page() {
    while true; do
        local COUNT=$(jq 'length' "$VPS_FILE")
        for i in $(seq 0 $((COUNT-1))); do
            local URL=$(jq -r ".[$i].url" "$VPS_FILE")
            if ! curl -Is "$URL" | head -1 | grep -q "200"; then
                send_tg "⚠️ VPS 续期页面无法访问：$URL"
            fi
        done
        sleep 3600
    done
}

# ==================== Telegram 命令处理 ====================
handle_commands() {
    local OFFSET=0
    while true; do
        local UPDATES=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?offset=$OFFSET")
        local COUNT=$(echo "$UPDATES" | jq '.result | length')
        if [ "$COUNT" -gt 0 ]; then
            for i in $(seq 0 $((COUNT-1))); do
                local UPDATE_ID=$(echo "$UPDATES" | jq ".result[$i].update_id")
                local MESSAGE=$(echo "$UPDATES" | jq -r ".result[$i].message.text")
                OFFSET=$((UPDATE_ID+1))
                
                case "$MESSAGE" in
                    /start)
                        send_tg "📌 可用命令：\n/add 名称|URL|到期日期\n/seturl 名称 新URL\n/setdate 名称 YYYY-MM-DD\n/del 名称\n/list"
                        ;;
                    /list)
                        list_vps
                        ;;
                    /add*)
                        local ARGS=$(echo "$MESSAGE" | cut -d' ' -f2-)
                        IFS='|' read NAME URL DATE <<< "$ARGS"
                        add_vps "$NAME" "$URL" "$DATE"
                        ;;
                    /seturl*)
                        local ARGS=$(echo "$MESSAGE" | cut -d' ' -f2-)
                        NAME=$(echo "$ARGS" | cut -d' ' -f1)
                        URL=$(echo "$ARGS" | cut -d' ' -f2)
                        set_vps_url "$NAME" "$URL"
                        ;;
                    /setdate*)
                        local ARGS=$(echo "$MESSAGE" | cut -d' ' -f2-)
                        NAME=$(echo "$ARGS" | cut -d' ' -f1)
                        DATE=$(echo "$ARGS" | cut -d' ' -f2)
                        set_vps_date "$NAME" "$DATE"
                        ;;
                    /del*)
                        NAME=$(echo "$MESSAGE" | cut -d' ' -f2)
                        del_vps "$NAME"
                        ;;
                    *)
                        send_tg "无效命令"
                        ;;
                esac
            done
        fi
        sleep 2
    done
}

# ==================== 主函数 ====================
main() {
    init_config
    load_config
    send_tg "🔧 VPS续期机器人已启动"

    check_notify &
    check_page &
    handle_commands &
    
    wait
}

main
