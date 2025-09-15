#!/bin/bash

set -euo pipefail

LOG_LEVEL="INFO"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_ENDPOINT="api.telegram.org"
SLOTS=()
PHYSICAL_DRIVES=()

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "  --log-level LEVEL              Set log level (ERROR, WARN, INFO, DEBUG). Default: INFO"
    echo "  --telegram-bot-token TOKEN     Telegram bot token for notifications"
    echo "  --telegram-chat-id ID          Telegram chat ID for notifications"
    echo "  --telegram-custom-endpoint     Custom Telegram API endpoint (domain only). Default: api.telegram.org"
    echo "  --slot NUMBER                  Check specific slot (can be used multiple times)"
    echo "  --physical-drive PORT:BOX:BAY  Check specific drive (can be used multiple times)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --log-level)
            LOG_LEVEL="${2^^}"
            shift 2
            ;;
        --telegram-bot-token)
            TELEGRAM_BOT_TOKEN="$2"
            shift 2
            ;;
        --telegram-chat-id)
            TELEGRAM_CHAT_ID="$2"
            shift 2
            ;;
        --telegram-custom-endpoint)
            TELEGRAM_ENDPOINT="$2"
            shift 2
            ;;
        --slot)
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --slot must be a number"
                exit 1
            fi
            SLOTS+=("$2")
            shift 2
            ;;
        --physical-drive)
            if ! [[ "$2" =~ ^[0-9]+[A-Z]:[0-9]+:[0-9]+$ ]]; then
                echo "Error: --physical-drive must be in format PORT:BOX:BAY (e.g., 1I:2:1)"
                exit 1
            fi
            PHYSICAL_DRIVES+=("$2")
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

send_telegram_notification() {
    local message="$1"
    local status="$2"
    
    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        return 0
    fi
    
    local hostname=$(hostname)
    local emoji
    case "$status" in
        "success") emoji="✅" ;;
        "error") emoji="❌" ;;
        "warning") emoji="⚠️" ;;
        *) emoji="ℹ️" ;;
    esac
    
    local full_message="$emoji *HPE Array Check - $hostname*

$message

_$(date '+%Y-%m-%d %H:%M:%S')_"
    
    log "DEBUG" "Sending Telegram notification to chat $TELEGRAM_CHAT_ID"
    
    curl -s -X POST "https://$TELEGRAM_ENDPOINT/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"$TELEGRAM_CHAT_ID\",
            \"text\": \"$full_message\",
            \"parse_mode\": \"Markdown\"
        }" > /dev/null
    
    if [[ $? -eq 0 ]]; then
        log "DEBUG" "Telegram notification sent successfully"
    else
        log "WARN" "Failed to send Telegram notification"
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

if [[ ${#SLOTS[@]} -gt 0 ]]; then
    slots="${SLOTS[*]}"
    log "DEBUG" "Using specified slots: $slots"
else
    slots=$(echo "$controller_output" | grep -oP 'Slot \K\d+')
    if [[ -z "$slots" ]]; then
        log "ERROR" "No controller slots found"
        exit 1
    fi
    log "DEBUG" "Found slots: $slots"
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
        if [[ "$line" =~ physicaldrive\ ([^\ ]+)\ .*\(([^,]+),\ ([^\)]+)\):\ (.+) ]]; then
            drive_id="${BASH_REMATCH[1]}"
            size="${BASH_REMATCH[3]}"
            status="${BASH_REMATCH[4]}"
            
            if [[ ${#PHYSICAL_DRIVES[@]} -gt 0 ]]; then
                found=false
                for target_drive in "${PHYSICAL_DRIVES[@]}"; do
                    if [[ "$drive_id" == "$target_drive" ]]; then
                        found=true
                        break
                    fi
                done
                if [[ "$found" == "false" ]]; then
                    continue
                fi
            fi
            
            drive_count=$((drive_count + 1))
            
            if [[ "$status" != "OK" ]]; then
                log "ERROR" "Slot $slot drive $drive_id ($size) status: $status"
                drive_errors=1
            else
                log "INFO" "Slot $slot drive $drive_id ($size) status: OK"
            fi
        fi
    done <<< "$drive_output"
    
    if [[ ${#PHYSICAL_DRIVES[@]} -gt 0 ]]; then
        log "INFO" "Controller slot $slot checked $drive_count specified drives"
    else
        log "INFO" "Controller slot $slot has $drive_count physical drives"
    fi
done

if [[ $controller_errors -eq 0 && $drive_errors -eq 0 ]]; then
    log "INFO" "Health check completed successfully - no errors found"
    send_telegram_notification "All HPE Smart Array controllers and drives are healthy" "success"
    exit 0
else
    error_summary=""
    if [[ $controller_errors -gt 0 ]]; then
        error_summary="Controller errors detected"
    fi
    if [[ $drive_errors -gt 0 ]]; then
        if [[ -n "$error_summary" ]]; then
            error_summary="$error_summary and drive errors detected"
        else
            error_summary="Drive errors detected"
        fi
    fi
    
    log "ERROR" "Health check completed with errors found"
    send_telegram_notification "$error_summary. Check system logs for details." "error"
    exit 1
fi