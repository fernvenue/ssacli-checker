#!/bin/bash

set -euo pipefail

LOG_LEVEL="INFO"

show_usage() {
    echo "Usage: $0 [--log-level LEVEL]"
    echo "  --log-level LEVEL    Set log level (ERROR, WARN, INFO, DEBUG). Default: INFO"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --log-level)
            LOG_LEVEL="${2^^}"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

case "$LOG_LEVEL" in
    ERROR) LOG_LEVEL_NUM=1 ;;
    WARN) LOG_LEVEL_NUM=2 ;;
    INFO) LOG_LEVEL_NUM=3 ;;
    DEBUG) LOG_LEVEL_NUM=4 ;;
    *)
        echo "Invalid log level: $LOG_LEVEL"
        show_usage
        ;;
esac

log() {
    local level="$1"
    local message="$2"
    local level_num
    
    case "$level" in
        ERROR) level_num=1 ;;
        WARN) level_num=2 ;;
        INFO) level_num=3 ;;
        DEBUG) level_num=4 ;;
    esac
    
    if [[ $level_num -le $LOG_LEVEL_NUM ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    fi
}

log "INFO" "Starting HPE Smart Array health check"
log "DEBUG" "Log level set to: $LOG_LEVEL"

if ! command -v ssacli &> /dev/null; then
    log "ERROR" "ssacli command not found"
    exit 1
fi
log "DEBUG" "ssacli command found"

log "INFO" "Checking controller status"
log "DEBUG" "Executing: ssacli ctrl all show status"
controller_output=$(ssacli ctrl all show status 2>/dev/null)
if [[ $? -ne 0 || -z "$controller_output" ]]; then
    log "ERROR" "Failed to retrieve controller status"
    exit 1
fi
log "DEBUG" "Controller status retrieved successfully"

controller_errors=0
while IFS= read -r line; do
    if [[ "$line" =~ Smart\ Array.*Slot\ ([0-9]+) ]]; then
        slot="${BASH_REMATCH[1]}"
        log "INFO" "Found controller in slot $slot"
    elif [[ "$line" =~ Controller\ Status:\ (.+) ]]; then
        status="${BASH_REMATCH[1]}"
        if [[ "$status" != "OK" ]]; then
            log "ERROR" "Controller slot $slot status: $status"
            controller_errors=1
        else
            log "INFO" "Controller slot $slot status: OK"
        fi
    elif [[ "$line" =~ Cache\ Status:\ (.+) ]]; then
        status="${BASH_REMATCH[1]}"
        if [[ "$status" != "OK" && "$status" != "Not Configured" ]]; then
            log "WARN" "Controller slot $slot cache status: $status"
        else
            log "INFO" "Controller slot $slot cache status: $status"
        fi
    fi
done <<< "$controller_output"

slots=$(echo "$controller_output" | grep -oP 'Slot \K\d+')
if [[ -z "$slots" ]]; then
    log "ERROR" "No controller slots found"
    exit 1
fi

drive_errors=0
for slot in $slots; do
    log "INFO" "Checking physical drives for controller slot $slot"
    log "DEBUG" "Executing: ssacli ctrl slot=$slot pd all show status"
    drive_output=$(ssacli ctrl slot="$slot" pd all show status 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to retrieve physical drive status for slot $slot"
        drive_errors=1
        continue
    fi
    log "DEBUG" "Physical drive status retrieved for slot $slot"
    
    if [[ -z "$drive_output" ]]; then
        log "INFO" "No physical drives found for controller slot $slot"
        continue
    fi
    
    drive_count=0
    while IFS= read -r line; do
        if [[ "$line" =~ physicaldrive\ ([^:]+):.*\(([^,]+),\ ([^\)]+)\):\ (.+) ]]; then
            drive_id="${BASH_REMATCH[1]}"
            size="${BASH_REMATCH[3]}"
            status="${BASH_REMATCH[4]}"
            drive_count=$((drive_count + 1))
            
            if [[ "$status" != "OK" ]]; then
                log "ERROR" "Slot $slot drive $drive_id ($size) status: $status"
                drive_errors=1
            else
                log "INFO" "Slot $slot drive $drive_id ($size) status: OK"
            fi
        fi
    done <<< "$drive_output"
    
    log "INFO" "Controller slot $slot has $drive_count physical drives"
done

if [[ $controller_errors -eq 0 && $drive_errors -eq 0 ]]; then
    log "INFO" "Health check completed successfully - no errors found"
    exit 0
else
    log "ERROR" "Health check completed with errors found"
    exit 1
fi