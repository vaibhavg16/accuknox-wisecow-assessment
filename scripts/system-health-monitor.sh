#!/usr/bin/env bash
# System Health Monitor — CPU, Memory, Disk, Processes
# Alerts when thresholds exceeded; logs to file + console

set -euo pipefail

THRESHOLD_CPU=80
THRESHOLD_MEM=80
THRESHOLD_DISK=85
THRESHOLD_PROC=300
# Use user-writable log location
LOG_FILE="${HOME}/system-health.log"
ALERT_COOLDOWN=300  # seconds

alert() {
    local msg="$1"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ALERT: $msg" | tee -a "$LOG_FILE"
}

check_cpu() {
    local usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1)
    if (( usage > THRESHOLD_CPU )); then
        alert "CPU usage at ${usage}% (threshold: ${THRESHOLD_CPU}%)"
    fi
}

check_memory() {
    local usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
    if (( usage > THRESHOLD_MEM )); then
        alert "Memory usage at ${usage}% (threshold: ${THRESHOLD_MEM}%)"
    fi
}

check_disk() {
    local usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if (( usage > THRESHOLD_DISK )); then
        alert "Disk usage at ${usage}% (threshold: ${THRESHOLD_DISK}%)"
    fi
}

check_processes() {
    local count=$(ps aux --no-heading | wc -l)
    if (( count > THRESHOLD_PROC )); then
        alert "Process count at ${count} (threshold: ${THRESHOLD_PROC})"
    fi
}

main() {
    echo "[$(date)] Starting health checks..." | tee -a "$LOG_FILE"
    check_cpu
    check_memory
    check_disk
    check_processes
    echo "[$(date)] Checks complete." | tee -a "$LOG_FILE"
}

main
