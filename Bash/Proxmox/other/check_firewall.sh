#!/bin/bash

########################################
# Configuration
########################################
FIREWALL_IP="192.168.120.1"               # IP address of the OPNSense firewall
FIREWALL_VMID=100                         # VMID of the OPNSense firewall in Proxmox
CHECK_INTERVAL=30                         # Check every 30 seconds
MAX_ATTEMPTS=3                            # Number of consecutive failed pings before taking action
HOST_REBOOT_TIMEOUT=900                   # 15 minutes before the host reboots if the firewall VM is unresponsive
REMEDIATION_STEP_TIMEOUT=180              # 3 minutes max per remediation step
WAIT_AFTER_SUCCESSFUL_START=180           # 3 minutes wait after a successful VM start
LOGFILE="/var/log/opnsense_monitor.log"   # Log file for recording events
MAX_LOGFILE_SIZE=$((1 * 1024 * 1024 * 1024)) # 1 GB max size
LOGFILE_BACKUP="/var/log/opnsense_monitor.log.bak"

########################################
# Safety & Preparatory Checks
########################################

# Ensure script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Check if required commands are available
for cmd in qm ping stat timeout kill reboot awk grep sleep ps; do
    if ! command -v $cmd &>/dev/null; then
        echo "Required command '$cmd' not found. Exiting."
        exit 1
    fi
done

# Ensure the log directory exists
log_dir=$(dirname "$LOGFILE")
if [ ! -d "$log_dir" ]; then
    mkdir -p "$log_dir"
fi

########################################
# Functions
########################################

# Rotate logs if too large
check_logfile_size() {
    if [ -f "$LOGFILE" ]; then
        filesize=$(stat -c%s "$LOGFILE")
        if [ "$filesize" -ge "$MAX_LOGFILE_SIZE" ]; then
            mv "$LOGFILE" "$LOGFILE_BACKUP"
            echo "$(date): Log file exceeded $MAX_LOGFILE_SIZE bytes. Moved current log to $LOGFILE_BACKUP." > "$LOGFILE"
        fi
    fi
}

# Log events
log_event() {
    check_logfile_size
    echo "$(date): $1" >> "$LOGFILE"
}

# Log command outputs
log_command_output() {
    local output="$1"
    local exit_code="$2"
    local command="$3"
    if [ "$exit_code" -ne 0 ]; then
        log_event "ERROR: Command '$command' failed with exit code $exit_code. Output: $output"
    else
        log_event "Command '$command' succeeded. Output: $output"
    fi
}

# Ping check
check_firewall() {
    ping -c 1 -W 5 "$FIREWALL_IP" > /dev/null 2>&1
    return $?
}

# Wait for VM to become responsive
wait_for_vm() {
    local attempts=0
    local max_attempts=36  # 36 attempts * 5s = ~3 minutes
    local interval=5       # 5 seconds interval

    log_event "Waiting for VM $FIREWALL_VMID to become responsive..."
    while [ $attempts -lt $max_attempts ]; do
        if check_firewall; then
            log_event "VM $FIREWALL_VMID is responsive now."
            return 0
        fi
        attempts=$((attempts + 1))
        sleep $interval
    done
    log_event "VM $FIREWALL_VMID did not become responsive within the allotted time."
    return 1
}

# Reboot VM
reboot_vm() {
    log_event "Attempting to reboot VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT qm reboot $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "qm reboot $FIREWALL_VMID"
    if [ "$exit_code" -eq 0 ]; then
        wait_for_vm
    fi
    return $exit_code
}

# Reset VM
reset_vm() {
    log_event "Attempting to reset VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT qm reset $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "qm reset $FIREWALL_VMID"
    if [ "$exit_code" -eq 0 ]; then
        wait_for_vm
    fi
    return $exit_code
}

# Stop & Start VM
stop_and_start_vm() {
    log_event "Attempting to stop VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT qm stop $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "qm stop $FIREWALL_VMID"

    if [ "$exit_code" -eq 0 ]; then
        log_event "VM $FIREWALL_VMID stopped successfully. Waiting 20 seconds before starting."
        sleep 20
        log_event "Attempting to start VM $FIREWALL_VMID."
        output=$(timeout $REMEDIATION_STEP_TIMEOUT qm start $FIREWALL_VMID 2>&1)
        exit_code=$?
        log_command_output "$output" "$exit_code" "qm start $FIREWALL_VMID"

        if [ "$exit_code" -eq 0 ]; then
            log_event "VM $FIREWALL_VMID started successfully. Waiting $WAIT_AFTER_SUCCESSFUL_START seconds."
            sleep $WAIT_AFTER_SUCCESSFUL_START
            wait_for_vm
        fi

        return $exit_code
    else
        return 1
    fi
}

# Kill VM Process
kill_vm_process() {
    log_event "Attempting to kill KVM process for VM $FIREWALL_VMID."
    VM_PID=$(ps aux | grep "kvm -id $FIREWALL_VMID" | grep -v grep | awk '{print $2}')
    
    if [ -z "$VM_PID" ]; then
        log_event "ERROR: Could not find KVM process for VM $FIREWALL_VMID."
        return 1
    else
        log_event "Killing KVM process for VM $FIREWALL_VMID (PID: $VM_PID)."
        kill_output=$(timeout $REMEDIATION_STEP_TIMEOUT kill -9 $VM_PID 2>&1)
        kill_exit_code=$?
        log_command_output "$kill_output" "$kill_exit_code" "kill -9 $VM_PID"
        
        # Verify the process was killed
        if ps -p $VM_PID > /dev/null 2>&1; then
            log_event "ERROR: Failed to kill KVM process $VM_PID."
            return 1
        else
            log_event "KVM process $VM_PID successfully killed. Attempting to start VM $FIREWALL_VMID."
            output=$(timeout $REMEDIATION_STEP_TIMEOUT qm start $FIREWALL_VMID 2>&1)
            exit_code=$?
            log_command_output "$output" "$exit_code" "qm start $FIREWALL_VMID"

            if [ "$exit_code" -eq 0 ]; then
                log_event "VM $FIREWALL_VMID started successfully. Waiting $WAIT_AFTER_SUCCESSFUL_START seconds."
                sleep $WAIT_AFTER_SUCCESSFUL_START
                wait_for_vm
            fi

            return $exit_code
        fi
    fi
}

########################################
# Logging Initial Environment
########################################
log_event "------------------- Script Start -------------------"
log_event "Current PATH: $PATH"
log_event "Current User: $(whoami)"
log_event "Environment Variables: $(env)"
log_event "Script Owner: $(stat -c '%U' $0)"
log_event "Script Permissions: $(stat -c '%A' $0)"

########################################
# Signal Handling
########################################
terminate_script() {
    log_event "Received termination signal. Exiting gracefully..."
    exit 0
}

trap terminate_script SIGINT SIGTERM SIGHUP

########################################
# Main Monitoring Loop
########################################
attempt_counter=0
previous_failed=false

while true; do
    if check_firewall; then
        if [ "$previous_failed" = true ]; then
            log_event "Ping recovered successfully."
            previous_failed=false
        fi
        attempt_counter=0
    else
        previous_failed=true
        attempt_counter=$((attempt_counter + 1))
        log_event "Ping failed ($attempt_counter/$MAX_ATTEMPTS)"
    fi

    if [ $attempt_counter -ge $MAX_ATTEMPTS ]; then
        minutes_unresponsive=$(( (CHECK_INTERVAL * MAX_ATTEMPTS) / 60 ))
        log_event "Firewall unresponsive for $minutes_unresponsive minutes. Initiating remediation steps for VM $FIREWALL_VMID."

        remediation_start_time=$(date +%s)
        remediation_end_time=$((remediation_start_time + HOST_REBOOT_TIMEOUT))
        vm_recovered=false

        # Keep trying remediation steps until timeout
        while [ $(date +%s) -lt $remediation_end_time ]; do
            if reboot_vm && check_firewall; then
                log_event "Firewall responded after reboot."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5

            if reset_vm && check_firewall; then
                log_event "Firewall responded after reset."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5

            if stop_and_start_vm && check_firewall; then
                log_event "Firewall responded after stop/start."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5

            if kill_vm_process && check_firewall; then
                log_event "Firewall responded after killing VM process."
                vm_recovered=true
                previous_failed=false
                break
            fi

            log_event "Remediation attempt unsuccessful. Retrying until timeout."
            sleep 5
        done

        if [ "$vm_recovered" = true ]; then
            log_event "VM $FIREWALL_VMID recovered successfully."
            attempt_counter=0
        else
            log_event "All remediation attempts failed after $((HOST_REBOOT_TIMEOUT/60)) minutes. Rebooting the host."
            for vmid in $(qm list | awk 'NR>1 {print $1}'); do
                qm stop $vmid
                qm wait $vmid
            done
            log_event "Rebooting the host forcefully now."
            reboot -f
        fi
    fi

    sleep $CHECK_INTERVAL
done
