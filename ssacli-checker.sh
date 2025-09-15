#!/bin/bash

set -euo pipefail

log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

log "INFO" "Starting HPE Smart Array health check"

if ! command -v ssacli &> /dev/null; then
    log "ERROR" "ssacli command not found"
    exit 1
fi

log "INFO" "Checking controller status"
controller_output=$(ssacli ctrl all show status 2>/dev/null)
if [[ $? -ne 0 || -z "$controller_output" ]]; then
    log "ERROR" "Failed to retrieve controller status"
    exit 1
fi

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
    drive_output=$(ssacli ctrl slot="$slot" pd all show status 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to retrieve physical drive status for slot $slot"
        drive_errors=1
        continue
    fi
    
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