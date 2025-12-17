#!/usr/bin/expect -f

# ==================== 配置区 ====================

set DEVICES {
    { "192.168.0.202" "2226" "root" "htx115200" }
    { "192.168.0.202" "3336" "root" "htx115200" }
    { "192.168.0.202" "5556" "root" "htx115200" }
    { "192.168.0.202" "6666" "root" "htx115200" }
}

set INTERVAL_SECONDS 60
set TMP_DIR "/home/ubuntu/xxh/golf/golf_sync"
set SERVER_URL "http://192.168.0.202:3030/api/golf_stats"
set CURL_EXEC "/home/ubuntu/anaconda3/bin/curl"

# 确保临时目录存在
file mkdir $TMP_DIR

# ==================== 辅助函数 ====================

# 替代 exec date，减少系统调用，性能更高且不消耗文件句柄
proc get_timestamp {} {
    return [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
}

proc get_date_ymd {} {
    return [clock format [clock seconds] -format "%Y-%m-%d"]
}

proc scp_file {host port user password remote_path local_path} {
    set timeout 15
    set result_code 0
    
    # spawn 启动 scp
    spawn scp -o ConnectTimeout=10 -o port=$port -o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$user@$host:$remote_path" "$local_path"
    
    # 记录 spawn_id，防止变量污染
    set curr_spawn_id $spawn_id

    expect {
        -i $curr_spawn_id
        timeout {
            puts "错误: \[$host\] scp 操作超时 ($remote_path)。"
            set result_code 1
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
            puts "错误: \[$host\] 网络不可达 (No route to host)。"
            set result_code 1
        }
        "Connection refused" {
            puts "错误: \[$host\] 连接被拒绝 (Connection refused)。"
            set result_code 1
        }
        "permission denied" {
            puts "错误: \[$host\] 密码错误或权限拒绝。"
            set result_code 1
        }
        eof {
            # 正常结束
        }
    }

    # ================= 关键修复 =================
    # 无论上面发生了什么（超时、拒绝、成功），都必须关闭连接并回收进程
    # 使用 catch 防止已经关闭的管道报错
    catch {close -i $curr_spawn_id}
    
    # wait 回收僵尸进程，释放系统表资源
    catch {wait -i $curr_spawn_id} result_list
    
    # 如果 expect 逻辑中已经标记失败，直接返回 1
    if {$result_code == 1} {
        return 1
    }

    # 检查进程退出码 (wait 返回列表的第4项是退出状态，0为成功)
    # 格式: {pid spawn_id os_error_code exit_code}
    if {[lindex $result_list 3] != 0} {
        puts "错误: \[$host\] scp 执行退出码非0 ($remote_path)。Code: [lindex $result_list 3]"
        return 1
    }

    return 0
}

proc read_file {path} {
    if {[file exists $path]} {
        if {[catch {
            set fd [open $path r]
            set data [read $fd]
            close $fd
        } err]} {
            puts "读取文件错误: $path - $err"
            return ""
        }
        return [string trim $data]
    } else {
        return ""
    }
}

# ==================== 单个设备处理逻辑 ====================

proc process_single_device {host port user password} {
    global TMP_DIR SERVER_URL CURL_EXEC

    set ts [get_timestamp]
    puts ">>> $ts 处理设备: $host:$port ($user)"

    # 清理旧的临时文件
    file delete "$TMP_DIR/data_store"
    file delete "$TMP_DIR/firmware_version"
    file delete "$TMP_DIR/dna_id"

    # 1. 从远程获取文件 (如果有任何一个失败，直接返回)
    if {[scp_file $host $port $user $password "/etc/configs/data_store" "$TMP_DIR/data_store"] != 0} { return }
    if {[scp_file $host $port $user $password "/etc/firmware_version" "$TMP_DIR/firmware_version"] != 0} { return }
    if {[scp_file $host $port $user $password "/etc/dna_id" "$TMP_DIR/dna_id"] != 0} { return }

    # 2. 获取 device_id 和 firmware_version
    set device_id [read_file "$TMP_DIR/dna_id"]
    if {$device_id eq ""} {
        puts "$ts: \[$host\] 错误: 无法读取 DNA ID，跳过"
        return
    }
    set firmware_version [read_file "$TMP_DIR/firmware_version"]
    if {$firmware_version eq ""} {
        set firmware_version "unknown"
    }
    
    puts "$ts: \[$host\] 设备ID: $device_id"
    set device_state_file "$TMP_DIR/${device_id}.state"

    # 3. 从 data_store 获取总击球数
    set content [read_file "$TMP_DIR/data_store"]
    set current_total_shottimes 0
    if {[regexp {shottimes:\s*([0-9]+)} $content -> count]} {
        set current_total_shottimes $count
    } else {
        puts "$ts: \[$host\] 错误: 无法解析击球数"
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
        puts "$ts: \[$host\] 检测到重置 (当前: $current_total_shottimes, 上次: $last_sent_shottimes)"
        set last_sent_shottimes 0
    }

    # 6. 计算新增
    set new_hits_count [expr {$current_total_shottimes - $last_sent_shottimes}]

    if {$new_hits_count > 0} {
        puts "$ts: \[$host\] 发现 $new_hits_count 次新击球"

        # 7. 构造 JSON
        set current_date [get_date_ymd]
        set json_payload "{\"device_id\": \"$device_id\", \"firmware_version\": \"$firmware_version\", \"daily_data\": {\"$current_date\": $new_hits_count}}"

        if {![file executable $CURL_EXEC]} {
            puts "$ts: 错误: CURL 不可用"
            return
        }

        # 8. 发送数据 (使用 catch 捕获 curl 执行错误)
        if {[catch {
            exec $CURL_EXEC -s -o /dev/null -w "%{http_code}" \
            -X POST -H "Content-Type: application/json" \
            -d $json_payload $SERVER_URL
        } response_code]} {
            puts "$ts: \[$host\] Curl 执行异常: $response_code"
            return
        }

        if {$response_code eq "200" || $response_code eq "201"} {
            set fd [open $device_state_file w]
            puts $fd $current_total_shottimes
            close $fd
            puts "$ts: \[$host\] 数据发送成功并更新状态"
        } else {
            puts "$ts: \[$host\] 数据发送失败, 响应码: $response_code"
        }
    } else {
        puts "$ts: \[$host\] 无新数据"
    }
}

# ==================== 主循环函数 ====================

proc run_all_devices {} {
    global DEVICES
    set ts [get_timestamp]
    puts "========================================"
    puts "$ts: 开始轮询所有设备..."

    foreach device $DEVICES {
        set host [lindex $device 0]
        set port [lindex $device 1]
        set user [lindex $device 2]
        set pass [lindex $device 3]

        if {[catch {process_single_device $host $port $user $pass} err]} {
            puts "!!! 严重错误: 处理设备 $host 时脚本发生异常: $err"
        }
    }
}

# ==================== 无限循环 ====================
while {1} {
    run_all_devices
    
    set ts [get_timestamp]
    puts "$ts: 所有设备轮询结束，休眠 $INTERVAL_SECONDS 秒..."
    
    # 强制进行一次垃圾回收（通常不需要，但在长时间运行脚本中可能有帮助）
    # Tcl 是自动管理的，但明确调用 update 可以处理挂起的事件
    update

    sleep $INTERVAL_SECONDS
}