#!/usr/bin/expect -f

# ==================== 配置区 ====================
set REMOTE_HOST "192.168.0.202"
set REMOTE_PORT "3336"
set REMOTE_USER "root"
set REMOTE_PASSWORD "htx115200"

set INTERVAL_SECONDS 60
set TMP_DIR "/home/ubuntu/xxh/golf/golf_sync"
set SERVER_URL "http://192.168.0.202:3030/api/golf_stats"
set CURL_EXEC "/home/ubuntu/anaconda3/bin/curl"

# 确保临时目录存在
file mkdir $TMP_DIR

# ==================== 辅助函数 ====================

# [修改] scp_file 函数，增加错误处理和资源回收
# 返回值: 0 表示成功, 1 表示失败
proc scp_file {remote_path local_path} {
    global REMOTE_HOST REMOTE_PORT REMOTE_USER REMOTE_PASSWORD
    
    # [新增] 设置一个连接超时，让scp在远程主机不在线时能快速失败
    set timeout 15
    spawn scp -o ConnectTimeout=10 -o port=$REMOTE_PORT -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$REMOTE_USER@$REMOTE_HOST:$remote_path" "$local_path"
    
    expect {
        timeout {
            puts "错误: scp 操作超时 ($remote_path)。远程主机可能已关闭或网络不通。"
            # [重要] 即使超时也要 close 和 wait 来清理僵尸进程
            close
            wait
            return 1
        }
        "The authenticity of host" {
            send "yes\r"
            exp_continue
        }
        "password:" {
            send "$REMOTE_PASSWORD\r"
            exp_continue
        }
        eof {
            # scp 进程已结束，但我们需要检查它是否成功
        }
    }

    # [重要] 清理 spawn 的子进程，防止资源泄漏
    # 使用 catch 是为了防止在进程已经异常关闭时 close 命令报错
    catch {close}
    # wait 命令获取子进程的退出状态
    set wait_result [wait]
    
    # wait 返回列表: [pid spawn_id os_error exit_code]
    # scp 成功时，exit_code (第四个元素) 为 0
    if {[lindex $wait_result 3] != 0} {
        puts "错误: scp 执行失败 ($remote_path)。可能远程文件不存在或权限问题。退出码: [lindex $wait_result 3]"
        return 1 ; # 返回失败状态
    }

    # 执行到这里说明 scp 成功
    return 0 ; # 返回成功状态
}

proc read_file {path} {
    if {[file exists $path]} {
        set fd [open $path r]
        set data [read $fd]
        close $fd
        return [string trim $data]
    } else {
        return ""
    }
}

# ==================== 主循环函数 ====================

proc process_and_send_logs {} {
    global TMP_DIR SERVER_URL CURL_EXEC

    set current_timestamp [exec date]
    puts "----------------------------------------"
    puts "$current_timestamp: 开始新一轮数据检查..."

    # 1. 从远程获取文件，并检查是否成功
    if {[scp_file "/etc/configs/data_store" "$TMP_DIR/data_store"] != 0} {
        puts "$current_timestamp: 无法获取 data_store 文件，跳过本次处理。"
        return
    }
    if {[scp_file "/etc/firmware_version" "$TMP_DIR/firmware_version"] != 0} {
        puts "$current_timestamp: 无法获取 firmware_version 文件，跳过本次处理。"
        return
    }
    if {[scp_file "/etc/dna_id" "$TMP_DIR/dna_id"] != 0} {
        puts "$current_timestamp: 无法获取 dna_id 文件，跳过本次处理。"
        return
    }

    # 2. 获取 device_id 和 firmware_version
    set device_id [read_file "$TMP_DIR/dna_id"]
    if {$device_id eq ""} {
        puts "$current_timestamp: 错误: 无法获取 DNA ID，跳过本次处理"
        return
    }
    set firmware_version [read_file "$TMP_DIR/firmware_version"]
    if {$firmware_version eq ""} {
        set firmware_version "unknown"
    }
    
    puts "$current_timestamp: 当前设备ID: $device_id"
    set device_state_file "$TMP_DIR/${device_id}.state"
    puts "$current_timestamp: 使用状态文件: $device_state_file"

    # 3. 从 data_store 获取总击球数
    set content [read_file "$TMP_DIR/data_store"]
    set current_total_shottimes 0
    if {[regexp {shottimes:\s*([0-9]+)} $content -> count]} {
        set current_total_shottimes $count
    } else {
        puts "$current_timestamp: 错误: 无法解析击球数"
        return
    }

    # 4. 读取上次已发送击球数（增加健壮性检查）
    set last_sent_shottimes 0
    if {[file exists $device_state_file]} {
        set read_value [read_file $device_state_file]
        if {[string is integer -strict $read_value]} {
            set last_sent_shottimes $read_value
        } else {
            puts "$current_timestamp: 警告: 状态文件 '$device_state_file' 为空或内容无效。将上次击球数视为 0。"
        }
    }

    # 5. 处理总数重置
    if {$current_total_shottimes < $last_sent_shottimes} {
        puts "$current_timestamp: 检测到总击球数重置 (当前: $current_total_shottimes, 上次: $last_sent_shottimes)"
        set last_sent_shottimes 0
    }

    # 6. 计算新增击球数
    set new_hits_count [expr {$current_total_shottimes - $last_sent_shottimes}]

    if {$new_hits_count > 0} {
        puts "$current_timestamp: 发现 $new_hits_count 次新击球 (总数: $current_total_shottimes)"

        # 7. 构造 JSON
        set current_date [exec date +%Y-%m-%d]
        set json_payload "{\"device_id\": \"$device_id\", \"firmware_version\": \"$firmware_version\", \"daily_data\": {\"$current_date\": $new_hits_count}}"

        if {![file executable $CURL_EXEC]} {
            puts "$current_timestamp: 错误: curl 不存在或不可执行 at $CURL_EXEC"
            return
        }

        # 8. 发送数据
        set response_code [exec $CURL_EXEC -s -o /dev/null -w "%{http_code}" \
            -X POST -H "Content-Type: application/json" \
            -d $json_payload $SERVER_URL]

        if {$response_code eq "200" || $response_code eq "201"} {
            puts "$current_timestamp: 数据发送成功"
            set fd [open $device_state_file w]
            puts $fd $current_total_shottimes
            close $fd
            puts "$current_timestamp: 已将总击球数 $current_total_shottimes 更新到 $device_state_file"
        } else {
            puts "$current_timestamp: 数据发送失败, 响应码: $response_code"
        }
    } else {
        puts "$current_timestamp: 没有新的击球数据 (当前总数: $current_total_shottimes, 上次记录: $last_sent_shottimes)"
    }
}

# ==================== 无限循环 ====================
while {1} {
    process_and_send_logs
    set current_timestamp [exec date]
    puts "$current_timestamp: 任务完成，休眠 $INTERVAL_SECONDS 秒..."
    # 使用 expect 内置的 sleep，比 exec sleep 略微高效
    sleep $INTERVAL_SECONDS
}
