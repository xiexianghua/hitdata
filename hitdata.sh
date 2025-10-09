#!/bin/bash

sleep 10 && route del default
sleep 10 && route add default gw 192.168.147.1
echo "nameserver 223.5.5.5" > /etc/resolv.conf
# sleep 10 && /etc/configs/easytier-core -w midsumm3r --machine-id ae489e42-220b-644b-6638-984f773edb95 > /etc/configs/my.log 2>&1 &

# ==================== 配置区 (请务必检查和修改) ====================

# 1. 每次循环的间隔时间 (单位: 秒)
#    例如: 600秒 = 10分钟; 900秒 = 15分钟
INTERVAL_SECONDS=900

# 2. 日志文件和状态文件的存放目录
LOG_DIR="/var/greenjoy/algorithm"
STATE_DIR="/var/greenjoy/algorithm_stats"

# 3. 接收数据的服务器API端点
#    !!! 必须修改为你的真实服务器地址 !!!
SERVER_URL="http://192.168.8.166:3030/api/golf_stats"

# 4. 用于获取设备DNA的路径
#   !!! 务必检查此项 !!! 
DNA_ID_PATH="/etc/dna_id"

# 5. 【重要】CURL工具的唯一指定路径
#    脚本将且仅将使用此路径的curl。如果它不存在或不可执行，数据将无法发送。
CURL_EXEC="/etc/configs/curl-aarch64"


# ==================== 核心逻辑函数 (处理和发送数据) ====================

process_and_send_logs() {
    echo "----------------------------------------"
    echo "$(date): 开始新一轮数据检查..."

    # 1. 获取设备唯一标识
    local device_id
    device_id=$(cat "$DNA_ID_PATH" 2>/dev/null)
    if [ -z "$device_id" ]; then
        echo "$(date): 错误: 无法获取设备 '$DNA_ID_PATH' 的DNA。"
        return 1 # 返回错误码，但不退出循环
    fi

    # 创建一个临时文件来汇总计数
    local temp_counts_file
    temp_counts_file=$(mktemp)
    # 确保函数退出时删除临时文件
    trap 'rm -f "$temp_counts_file"' RETURN

    # ==================== 已禁用：归档日志处理 ====================
    # 以下代码块已被禁用，以防止在日志轮转时重复计算数据。
    # 此前，该逻辑会重新处理整个归档文件，导致数据异常增加。
    # 禁用此功能可确保数据准确性，但可能导致轮转瞬间的少量数据丢失。
    #
    # shopt -s nullglob
    # local archived_logs=("$LOG_DIR"/log_*.txt)
    # shopt -u nullglob
    # if [ ${#archived_logs[@]} -gt 0 ]; then
    #     echo "$(date): 发现 ${#archived_logs[@]} 个归档日志，正在处理..."
    #     # 核心处理管道: 筛选 -> 提取日期 -> 排序 -> 计数
    #     cat "${archived_logs[@]}" | grep "Final Result:" | cut -d' ' -f1 | sed 's/\[//' | sort | uniq -c | awk '{print $1" "$2}' >> "$temp_counts_file"
    #     # 移动已处理的文件
    #     mv "${archived_logs[@]}" "$STATE_DIR/processed_logs/"
    # fi
    # ============================================================

    # 3. 处理活动的日志 (log)
    local active_log_file="$LOG_DIR/log"
    if [ -f "$active_log_file" ]; then
        local state_file="$STATE_DIR/active_log.state"
        local last_line_processed
        last_line_processed=$(cat "$state_file" 2>/dev/null || echo 0)
        
        local current_total_lines
        current_total_lines=$(wc -l < "$active_log_file")

        if [ "$current_total_lines" -lt "$last_line_processed" ]; then
            last_line_processed=0
            echo "$(date): 检测到活动日志已轮转，从头开始处理。"
        fi

        local new_lines_count=$((current_total_lines - last_line_processed))
        if [ "$new_lines_count" -gt 0 ]; then
            echo "$(date): 发现 $new_lines_count 条新日志，正在处理..."
            tail -n "$new_lines_count" "$active_log_file" | grep "Final Result:" | cut -d' ' -f1 | sed 's/\[//' | sort | uniq -c | awk '{print $1" "$2}' >> "$temp_counts_file"
            echo "$current_total_lines" > "$state_file"
        fi
    fi

    # 4. 聚合所有新数据并构建JSON
    if [ -s "$temp_counts_file" ]; then
        # 使用 awk 来合并相同日期的计数
        local aggregated_data
        aggregated_data=$(awk '{counts[$2] += $1} END {for (date in counts) print date ":" counts[date]}' "$temp_counts_file")

        # 获取固件版本
        local firmware_version
        firmware_version=$(cat /etc/firmware_version 2>/dev/null || echo "unknown")

        # 【已修正】构建JSON负载
        local json_payload
        json_payload="{\"device_id\": \"$device_id\", \"firmware_version\": \"$firmware_version\", \"daily_data\": {"
        local first=true
        for item in $aggregated_data; do
            local date count
            date=$(echo "$item" | cut -d':' -f1)
            count=$(echo "$item" | cut -d':' -f2)
            if [ "$first" = false ]; then json_payload+=","; fi
            json_payload+="\"$date\": $count"
            first=false
        done
        json_payload+="}}"
        
        # ==================== 数据发送部分 (仅使用指定curl) ====================
        
        # 严格检查指定的curl是否存在且可执行
        if [ ! -x "$CURL_EXEC" ]; then
            echo "$(date): 错误: 指定的curl '$CURL_EXEC' 不存在或不可执行。本次无法发送数据。"
            return 1 # 返回错误，但主循环将继续
        fi

        echo "$(date): 使用 '$CURL_EXEC' 发送JSON: $json_payload"
        
        # 5. 使用 curl 发送数据
        local response_code
        response_code=$("$CURL_EXEC" -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            "$SERVER_URL")
        
        if [[ "$response_code" == "200" || "$response_code" == "201" ]]; then
            echo "$(date): 数据发送成功！服务器响应码: $response_code"
        else
            echo "$(date): 错误: 数据发送失败！服务器响应码: $response_code"
        fi
        # ==================== 数据发送部分修改结束 ====================

    else
        echo "$(date): 没有发现新的击球数据。"
    fi
}

# ==================== 主循环 ====================

# 确保状态目录存在，这只需要在启动时运行一次
mkdir -p "$STATE_DIR/processed_logs"
echo "脚本已启动。将进入无限循环，每 ${INTERVAL_SECONDS} 秒执行一次任务。"
echo "请使用 'nohup ./your_script_name.sh &> /var/log/hitlog.log &' 将其在后台稳定运行。"

while true; do
    process_and_send_logs
    echo "$(date): 任务完成，将休眠 $INTERVAL_SECONDS 秒..."
    sleep "$INTERVAL_SECONDS"
done