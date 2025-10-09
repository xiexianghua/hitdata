#!/bin/bash

sleep 10 && route del default
sleep 10 && route add default gw 192.168.147.1
echo "nameserver 223.5.5.5" > /etc/resolv.conf
# sleep 10 && /etc/configs/easytier-core -w midsumm3r --machine-id ae489e42-220b-644b-6638-984f773edb95 > /etc/configs/my.log 2>&1 &

# ==================== 配置区 (请务必检查和修改) ====================

# 1. 每次循环的间隔时间 (单位: 秒)
#    例如: 600秒 = 10分钟; 900秒 = 15分钟
INTERVAL_SECONDS=20

# 2. 日志文件和状态文件的存放目录
LOG_DIR="/var/greenjoy/algorithm"
STATE_DIR="/var/greenjoy/algorithm_stats"

# 3. 接收数据的服务器API端点
#    !!! 必须修改为你的真实服务器地址 !!!
SERVER_URL="http://192.168.0.202:3030/api/golf_stats"

# 4. 用于获取设备DNA的路径
#   !!! 务必检查此项 !!! 
DNA_ID_PATH="/etc/dna_id"

# 5. 【重要】CURL工具的唯一指定路径
#    脚本将且仅将使用此路径的curl。如果它不存在或不可执行，数据将无法发送。
CURL_EXEC="/etc/configs/curl-aarch64"

# 6. 【新增】用于获取击球数和记录状态的文件路径 (请勿修改)
DATA_STORE_FILE="/etc/configs/data_store"
STATE_FILE_SHOTTIMES="$STATE_DIR/last_sent_shottimes.state"


# ==================== 核心逻辑函数 (处理和发送数据) ====================

process_and_send_logs() {
    echo "----------------------------------------"
    echo "$(date): 开始新一轮数据检查..."

    # 1. 获取设备唯一标识和固件版本
    local device_id firmware_version
    device_id=$(cat "$DNA_ID_PATH" 2>/dev/null)
    if [ -z "$device_id" ]; then
        echo "$(date): 错误: 无法获取设备 '$DNA_ID_PATH' 的DNA。"
        return 1 # 返回错误码，但不退出循环
    fi
    firmware_version=$(cat /etc/firmware_version 2>/dev/null || echo "unknown")

    # 2. 从 data_store 获取当前总击球数
    if [ ! -r "$DATA_STORE_FILE" ]; then
        echo "$(date): 错误: 数据文件 '$DATA_STORE_FILE' 不存在或不可读。"
        return 1
    fi
    local current_total_shottimes
    # 使用 awk 精准提取shottimes后的数字，并用 tr 删除可能的空白符
    current_total_shottimes=$(awk -F': *' '/shottimes:/ {print $2}' "$DATA_STORE_FILE" | tr -d '[:space:]')
    if ! [[ "$current_total_shottimes" =~ ^[0-9]+$ ]]; then
        echo "$(date): 错误: 无法从 '$DATA_STORE_FILE' 中解析有效的击球数。"
        return 1
    fi

    # 3. 获取上次成功发送的击球总数
    local last_sent_shottimes
    last_sent_shottimes=$(cat "$STATE_FILE_SHOTTIMES" 2>/dev/null || echo 0)

    # 4. 处理总数重置的情况 (例如，设备恢复出厂设置)
    if [ "$current_total_shottimes" -lt "$last_sent_shottimes" ]; then
        echo "$(date): 检测到总击球数已重置 (当前: $current_total_shottimes, 上次记录: $last_sent_shottimes)。将从当前总数开始重新计算。"
        last_sent_shottimes=0
    fi

    # 5. 计算本次需要发送的【新增】击球数
    local new_hits_count=$((current_total_shottimes - last_sent_shottimes))

    # 6. 检查是否有新的击球数据需要发送
    if [ "$new_hits_count" -gt 0 ]; then
        echo "$(date): 发现 $new_hits_count 次新击球 (当前总数: $current_total_shottimes)。准备发送..."
        
        # 构建JSON负载
        local current_date
        current_date=$(date +%Y-%m-%d)
        local json_payload
        # 使用 printf 安全地构建JSON，避免特殊字符问题
        json_payload=$(printf '{"device_id": "%s", "firmware_version": "%s", "daily_data": {"%s": %d}}' \
            "$device_id" \
            "$firmware_version" \
            "$current_date" \
            "$new_hits_count")

        # 严格检查指定的curl是否存在且可执行
        if [ ! -x "$CURL_EXEC" ]; then
            echo "$(date): 错误: 指定的curl '$CURL_EXEC' 不存在或不可执行。数据未发送，状态未更新。"
            return 1
        fi

        echo "$(date): 使用 '$CURL_EXEC' 发送JSON: $json_payload"
        
        # 使用 curl 发送数据，并获取HTTP响应码
        local response_code
        response_code=$("$CURL_EXEC" -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            "$SERVER_URL")
        
        # 【关键】根据服务器响应决定是否更新状态
        if [[ "$response_code" == "200" || "$response_code" == "201" ]]; then
            echo "$(date): 数据发送成功！服务器响应码: $response_code"
            # 仅在发送成功后，将当前的 *总数* 写入状态文件，作为新的标记点
            echo "$current_total_shottimes" > "$STATE_FILE_SHOTTIMES"
            echo "$(date): 状态已更新，已发送总击球数标记为: $current_total_shottimes"
        else
            echo "$(date): 错误: 数据发送失败！服务器响应码: $response_code"
            echo "$(date): 重要: 状态文件未更新，将在下一周期重试发送这 $new_hits_count 次击球。"
        fi
    else
        echo "$(date): 没有发现新的击球数据。"
    fi
}

# ==================== 主循环 ====================

# 确保状态目录存在，这只需要在启动时运行一次
mkdir -p "$STATE_DIR"
echo "脚本已启动。将进入无限循环，每 ${INTERVAL_SECONDS} 秒执行一次任务。"
echo "请使用 'nohup ./your_script_name.sh &> /var/log/hitlog.log &' 将其在后台稳定运行。"

while true; do
    process_and_send_logs
    echo "$(date): 任务完成，将休眠 $INTERVAL_SECONDS 秒..."
    sleep "$INTERVAL_SECONDS"
done