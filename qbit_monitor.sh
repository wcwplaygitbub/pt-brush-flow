#!/bin/bash

# 配置参数
QBIT_SERVICE="qbittorrent-nox@wcwtest.service"  # systemd服务名
QBIT_PROCESS="qbittorrent-nox"  # 精确的进程名
QBIT_COMMAND="/usr/bin/qbittorrent-nox -d"  # 带-daemon参数的启动命令
RUN_AS_USER="wcwtest"            # 运行用户
SPEEDTEST_THRESHOLD_LOW=300      # 低速阈值(Mbps)
SPEEDTEST_THRESHOLD_HIGH=500     # 高速阈值(Mbps)
QBIT_CHECK_SPEEDTEST_THRESHOLD_LOW=200     # qbit check低速阈值(Mbps)
NETWORK_INTERFACE="eth0"        # 监控的网络接口
LOG_FILE="/var/log/qbit_monitor.log"

# 初始化日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 安装必要工具
check_install_dependencies() {
        # Check and install nethogs
    if command -v nethogs &>/dev/null; then
        log "nethogs is already installed"
    else
        log "Installing nethogs..."
        if ! apt-get update || ! apt-get install -y nethogs; then
            log "ERROR: Failed to install nethogs"
            exit 1
        fi
        # Verify installation
        if ! command -v nethogs &>/dev/null; then
            log "ERROR: nethogs installation verification failed"
            exit 1
        fi
        log "nethogs installed successfully"
    fi
    
        # Check and install bc
    if command -v bc &>/dev/null; then
        log "bc is already installed"
    else
        log "Installing bc..."
        if ! apt-get update || ! apt-get install -y bc; then
            log "ERROR: Failed to install bc"
            exit 1
        fi
        # Verify installation
        if ! command -v bc &>/dev/null; then
            log "ERROR: bc installation verification failed"
            exit 1
        fi
        log "bc installed successfully"
    fi

    # Check and install speedtest-cli
    if command -v speedtest-cli &>/dev/null; then
        log "speedtest-cli is already installed"
    else
        log "Installing speedtest-cli..."
        if ! apt-get update || ! apt-get install -y speedtest-cli; then
            log "ERROR: Failed to install speedtest-cli"
            exit 1
        fi
        # Verify installation
        if ! command -v speedtest-cli &>/dev/null; then
            log "ERROR: speedtest-cli installation verification failed"
            exit 1
        fi
        log "speedtest-cli installed successfully"
    fi
}

# 函数：检查qBittorrent是否运行
is_qbit_running() {
    systemctl is-active --quiet "$QBIT_SERVICE"
}

# 函数：获取qBittorrent的5秒平均下载速度(Mbps)
get_qbit_speed() {
     # 临时文件存储采样数据
    local tmp_file=$(mktemp)
    
    # 运行nethogs采样5秒（每秒1次，共5次）
    timeout 5 nethogs -t -d 1 -c 5 > "$tmp_file" 2>&1
    
    # 提取所有采样点的上下行速度
    local speeds=$(grep "$QBIT_PROCESS" "$tmp_file" | awk '{print $2,$3}')
    rm "$tmp_file"
    
    # 如果没有数据返回0
    [ -z "$speeds" ] && { echo 0; return; }
    
    # 计算所有采样点的最大值（KB/s）
    local max_kbs=$(echo "$speeds" | awk '
        BEGIN { max = 0 }
        {
            if ($1 > max) max = $1
            if ($2 > max) max = $2
        }
        END { print max }
    ')
    
    # 转换为Mbps并保留2位小数
    awk -v kb="$max_kbs" 'BEGIN { printf "%.2f", kb * 0.008 }'
}

# 函数：执行speedtest测试
run_speedtest() {
    log "Running speedtest..."
    result=$(speedtest-cli --simple 2>/dev/null)
    
    if [ -z "$result" ]; then
        log "Speedtest failed, start qbit"
        start_qbit
        return 1
    fi
    
    download=$(echo "$result" | grep Download | awk '{print $2}')
    upload=$(echo "$result" | grep Upload | awk '{print $2}')
    log "Speedtest results - Download: $download Mbps, Upload: $upload Mbps"
    
    # 返回下载和上传速度
    echo "$download $upload"
}

# 函数：停止qBittorrent
stop_qbit() {
    log "Stopping qBittorrent..."
    systemctl stop "$QBIT_SERVICE"
    # 等待进程完全停止
    for i in {1..10}; do
        if ! is_qbit_running; then
            log "qbit Service stopped successfully"
            return 0
        fi
        sleep 1
    done
    if is_qbit_running; then
        log "Warning: Failed to stop qBittorrent gracefully, forcing kill..."
        pkill -9 -f "$QBIT_PROCESS"
    fi
}

# 函数：启动qBittorrent
start_qbit() {
    log "Starting $QBIT_SERVICE..."
    if systemctl start "$QBIT_SERVICE"; then
        # 等待服务完全启动
        for i in {1..10}; do
            if is_qbit_running; then
                log "qbit Service started successfully"
                return 0
            fi
            sleep 1
        done
    fi
    
    log "Error: Failed to start qbit service"
    return 1
}

# 主逻辑
log "=== Starting qBittorrent monitor ==="
log "=begin to check tools that we need ="
check_install_dependencies
log "=end check tools that we need ="

if is_qbit_running; then
    log "qBittorrent is running, checking speed..."
    speed=$(get_qbit_speed)
    log "Current qBittorrent download speed: ${speed}Mbps"
    
    if (( $(echo "$speed > $QBIT_CHECK_SPEEDTEST_THRESHOLD_LOW" | bc -l) )); then
        log "qBittorrent Speed is good, exiting..."
        exit 0
    else
        log "qBittorrent Speed is slow, stop qbit process..."
        stop_qbit
        read -r download upload <<< $(run_speedtest)
        
        if [ -z "$download" ] || [ -z "$upload" ]; then
            log "Speedtest failed, exiting..."
            exit 1
        fi
        
        if (( $(echo "$download > $SPEEDTEST_THRESHOLD_LOW && $upload > $SPEEDTEST_THRESHOLD_LOW" | bc -l) )); then
            log "Network speed recovered, restarting qBittorrent..."
            start_qbit
        else
            log "Network speed still low, keeping qBittorrent stopped..."
        fi
    fi
else
    log "qBittorrent is not running, checking network..."
    read -r download upload <<< $(run_speedtest)
    
    if [ -z "$download" ] || [ -z "$upload" ]; then
        log "Speedtest failed, exiting..."
        exit 1
    fi
    
    if (( $(echo "$download > $SPEEDTEST_THRESHOLD_HIGH || $upload > $SPEEDTEST_THRESHOLD_HIGH" | bc -l) )); then
        log "Network speed is high, starting qBittorrent..."
        start_qbit
    else
        log "Network speed not sufficient, keeping qBittorrent stopped..."
    fi
fi

log "=== Monitoring cycle completed ==="
exit 0