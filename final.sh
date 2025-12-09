#!/usr/bin/expect -f

# ==================== 配置区 ====================

# 格式: { "IP地址" "端口" "用户名" "密码" }
set DEVICES {
    { "192.168.0.202" "2226" "root" "htx115200" }
    { "192.168.0.202" "3336" "root" "htx115200" }
}

set INTERVAL_SECONDS 60
set TMP_DIR "/home/ubuntu/xxh/golf/golf_sync"
set SERVER_URL "http://192.168.0.202:3030/api/golf_stats"
set CURL_EXEC "/home/ubuntu/anaconda3/bin/curl"

# 确保临时目录存在
file mkdir $TMP_DIR

# ==================== 辅助函数 ====================

proc scp_file {host port user password remote_path local_path} {
    
    set timeout 15
    # spawn 启动 scp
    spawn scp -o ConnectTimeout=10 -o port=$port -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$user@$host:$remote_path" "$local_path"
    
    expect {
        timeout {
            # [修复] 这里的 [$host] 必须转义为 \[$host\]
            puts "错误: \[$host\] scp 操作超时 ($remote_path)。"
            close
            wait
            return 1
        }
        "The authenticity of host" {
            send "yes\r"
            exp_continue
        }
        "password:" {
            send "$password\r"
            exp_continue
        }
        "No route to host" {
            # 捕获常见的 SSH 错误文本
            puts "错误: \[$host\] 网络不可达 (No route to host)。"
            return 1
        }
        "Connection refused" {
            puts "错误: \[$host\] 连接被拒绝 (Connection refused)。"
            return 1
        }
        eof {
            # 进程结束，等待 wait 获取结果
        }
    }

    catch {close}
    set wait_result [wait]
    
    # scp 成功时 exit_code 为 0
    if {[lindex $wait_result 3] != 0} {
        # [修复] 转义方括号
        puts "错误: \[$host\] scp 执行失败 ($remote_path)。退出码: [lindex $wait_result 3]"
        return 1
    }

    return 0
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

# ==================== 单个设备处理逻辑 ====================

proc process_single_device {host port user password} {
    global TMP_DIR SERVER_URL CURL_EXEC

    set current_timestamp [exec date]
    puts ">>> 处理设备: $host:$port ($user)"

    # 清理旧的临时文件，防止数据混淆
    file delete "$TMP_DIR/data_store"
    file delete "$TMP_DIR/firmware_version"
    file delete "$TMP_DIR/dna_id"

    # 1. 从远程获取文件
    if {[scp_file $host $port $user $password "/etc/configs/data_store" "$TMP_DIR/data_store"] != 0} {
        puts "$current_timestamp: \[$host\] 无法获取 data_store，跳过。"
        return
    }
    if {[scp_file $host $port $user $password "/etc/firmware_version" "$TMP_DIR/firmware_version"] != 0} {
        puts "$current_timestamp: \[$host\] 无法获取 firmware_version，跳过。"
        return
    }
    if {[scp_file $host $port $user $password "/etc/dna_id" "$TMP_DIR/dna_id"] != 0} {
        puts "$current_timestamp: \[$host\] 无法获取 dna_id，跳过。"
        return
    }

    # 2. 获取 device_id 和 firmware_version
    set device_id [read_file "$TMP_DIR/dna_id"]
    if {$device_id eq ""} {
        puts "$current_timestamp: \[$host\] 错误: 无法读取 DNA ID，跳过"
        return
    }
    set firmware_version [read_file "$TMP_DIR/firmware_version"]
    if {$firmware_version eq ""} {
        set firmware_version "unknown"
    }
    
    puts "$current_timestamp: \[$host\] 设备ID: $device_id"
    set device_state_file "$TMP_DIR/${device_id}.state"

    # 3. 从 data_store 获取总击球数
    set content [read_file "$TMP_DIR/data_store"]
    set current_total_shottimes 0
    if {[regexp {shottimes:\s*([0-9]+)} $content -> count]} {
        set current_total_shottimes $count
    } else {
        puts "$current_timestamp: \[$host\] 错误: 无法解析击球数"
        return
    }

    # 4. 读取上次已发送击球数
    set last_sent_shottimes 0
    if {[file exists $device_state_file]} {
        set read_value [read_file $device_state_file]
        if {[string is integer -strict $read_value]} {
            set last_sent_shottimes $read_value
        }
    }

    # 5. 处理总数重置
    if {$current_total_shottimes < $last_sent_shottimes} {
        puts "$current_timestamp: \[$host\] 检测到重置 (当前: $current_total_shottimes, 上次: $last_sent_shottimes)"
        set last_sent_shottimes 0
    }

    # 6. 计算新增
    set new_hits_count [expr {$current_total_shottimes - $last_sent_shottimes}]

    if {$new_hits_count > 0} {
        puts "$current_timestamp: \[$host\] 发现 $new_hits_count 次新击球"

        # 7. 构造 JSON
        set current_date [exec date +%Y-%m-%d]
        set json_payload "{\"device_id\": \"$device_id\", \"firmware_version\": \"$firmware_version\", \"daily_data\": {\"$current_date\": $new_hits_count}}"

        if {![file executable $CURL_EXEC]} {
            puts "$current_timestamp: 错误: CURL 不可用"
            return
        }

        # 8. 发送数据
        set response_code [exec $CURL_EXEC -s -o /dev/null -w "%{http_code}" \
            -X POST -H "Content-Type: application/json" \
            -d $json_payload $SERVER_URL]

        if {$response_code eq "200" || $response_code eq "201"} {
            set fd [open $device_state_file w]
            puts $fd $current_total_shottimes
            close $fd
            puts "$current_timestamp: \[$host\] 数据发送成功并更新状态"
        } else {
            puts "$current_timestamp: \[$host\] 数据发送失败, 响应码: $response_code"
        }
    } else {
        puts "$current_timestamp: \[$host\] 无新数据"
    }
}

# ==================== 主循环函数 ====================

proc run_all_devices {} {
    global DEVICES
    set current_timestamp [exec date]
    puts "========================================"
    puts "$current_timestamp: 开始轮询所有设备..."

    foreach device $DEVICES {
        set host [lindex $device 0]
        set port [lindex $device 1]
        set user [lindex $device 2]
        set pass [lindex $device 3]

        # 使用 catch 捕获异常，防止一个设备报错导致整个脚本退出
        if {[catch {process_single_device $host $port $user $pass} err]} {
            # 这里的日志不再使用方括号，避免再次崩溃
            puts "!!! 严重错误: 处理设备 $host 时脚本发生异常: $err"
        }
    }
}

# ==================== 无限循环 ====================
while {1} {
    run_all_devices
    
    set current_timestamp [exec date]
    puts "$current_timestamp: 所有设备轮询结束，休眠 $INTERVAL_SECONDS 秒..."
    sleep $INTERVAL_SECONDS
}