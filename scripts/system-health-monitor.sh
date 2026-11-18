#!/usr/bin/env bash
# System Health Monitor — CPU, Memory, Disk, Processes
# Alerts when thresholds are exceeded; writes to both console and a log file.
#
# Usage:   ./system-health-monitor.sh
# Cron:    */5 * * * * /path/to/system-health-monitor.sh
#
# Exit code: 0 on completion (alerts are reported, not fatal), so the script
# can be cron-driven without a tripped threshold marking the job as failed.

set -euo pipefail

# ---- thresholds (percentage unless noted) --------------------------------
THRESHOLD_CPU=80
THRESHOLD_MEM=80
THRESHOLD_DISK=85
THRESHOLD_PROC=300

# User-writable log location, so the script runs unprivileged.
LOG_FILE="${HOME}/system-health.log"

alert() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] ALERT: $msg" | tee -a "$LOG_FILE"
}

check_cpu() {
    local usage
    usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1)
    # Guard: if the parse yields nothing, (( )) would raise a syntax error
    # under set -e rather than reading a zero.
    usage="${usage:-0}"
    if (( usage > THRESHOLD_CPU )); then
        alert "CPU usage at ${usage}% (threshold: ${THRESHOLD_CPU}%)"
    fi
}

check_memory() {
    local usage
    usage=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
    usage="${usage:-0}"
    if (( usage > THRESHOLD_MEM )); then
        alert "Memory usage at ${usage}% (threshold: ${THRESHOLD_MEM}%)"
    fi
}

check_disk() {
    local usage
    usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    usage="${usage:-0}"
    if (( usage > THRESHOLD_DISK )); then
        alert "Disk usage at ${usage}% (threshold: ${THRESHOLD_DISK}%)"
    fi
}

check_processes() {
    local count
    count=$(ps aux --no-heading | wc -l)
    count="${count:-0}"
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

