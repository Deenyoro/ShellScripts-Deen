#!/bin/bash

# Configuration
FIREWALL_IP="192.168.120.1"             # IP address of the OPNSense firewall
FIREWALL_VMID=100                       # VMID of the OPNSense firewall in Proxmox
CHECK_INTERVAL=30                       # Check every 30 seconds
MAX_ATTEMPTS=3                          # Number of consecutive failed pings before taking action
HOST_REBOOT_TIMEOUT=900                 # 15 minutes before the host reboots if the firewall VM is unresponsive
REMEDIATION_STEP_TIMEOUT=180            # 3 minutes max per remediation step
WAIT_AFTER_SUCCESSFUL_START=180         # 3 minutes wait after a successful VM start
LOGFILE="/var/log/opnsense_monitor.log" # Log file for recording events
MAX_LOGFILE_SIZE=$((1 * 1024 * 1024 * 1024)) # 1 GB max size

# Function to check the log file size and wipe it if it exceeds the limit
check_logfile_size() {
    if [ -f "$LOGFILE" ]; then
        filesize=$(stat -c%s "$LOGFILE")
        if [ "$filesize" -ge "$MAX_LOGFILE_SIZE" ]; then
            echo "$(date): Log file exceeded $MAX_LOGFILE_SIZE bytes. Wiping the log file." > "$LOGFILE"
        fi
    fi
}

# Function to log events with a timestamp
log_event() {
    check_logfile_size
    echo "$(date): $1" >> $LOGFILE
}

# Function to log command outputs and errors
log_command_output() {
    output="$1"
    exit_code="$2"
    command="$3"
    if [ "$exit_code" -ne 0 ]; then
        log_event "ERROR: Command '$command' failed with exit code $exit_code. Output: $output"
    else
        log_event "Command '$command' succeeded. Output: $output"
    fi
}

# Function to check the firewall's status using ping
check_firewall() {
    ping -c 1 -W 5 $FIREWALL_IP > /dev/null 2>&1
    return $?
}

# Function to wait for the VM to become responsive
wait_for_vm() {
    local attempts=0
    local max_attempts=36  # 3 minutes (36 attempts with 5 seconds interval)
    local interval=5       # 5 seconds interval between pings

    log_event "Waiting for VM $FIREWALL_VMID to become responsive..."
    while [ $attempts -lt $max_attempts ]; do
        if check_firewall; then
            log_event "VM $FIREWALL_VMID is responsive. Stopping remediation."
            return 0
        fi
        attempts=$((attempts + 1))
        sleep $interval
    done
    return 1
}

# Function to reboot the VM
reboot_vm() {
    log_event "Attempting to reboot VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT /usr/sbin/qm reboot $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "/usr/sbin/qm reboot"
    if [ "$exit_code" -eq 0 ]; then
        wait_for_vm
    fi
    return $exit_code
}

# Function to reset the VM
reset_vm() {
    log_event "Attempting to reset VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT /usr/sbin/qm reset $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "/usr/sbin/qm reset"
    if [ "$exit_code" -eq 0 ]; then
        wait_for_vm
    fi
    return $exit_code
}

# Function to stop the VM gracefully and start it again
stop_and_start_vm() {
    log_event "Attempting to stop VM $FIREWALL_VMID."
    output=$(timeout $REMEDIATION_STEP_TIMEOUT /usr/sbin/qm stop $FIREWALL_VMID 2>&1)
    exit_code=$?
    log_command_output "$output" "$exit_code" "/usr/sbin/qm stop"

    if [ "$exit_code" -eq 0 ]; then
        log_event "VM $FIREWALL_VMID stopped successfully."
        log_event "Waiting for 20 seconds before starting VM $FIREWALL_VMID."
        sleep 20
        log_event "Attempting to start VM $FIREWALL_VMID."
        output=$(timeout $REMEDIATION_STEP_TIMEOUT /usr/sbin/qm start $FIREWALL_VMID 2>&1)
        exit_code=$?
        log_command_output "$output" "$exit_code" "/usr/sbin/qm start"

        if [ "$exit_code" -eq 0 ]; then
            log_event "VM $FIREWALL_VMID started successfully. Waiting for $WAIT_AFTER_SUCCESSFUL_START seconds before proceeding."
            sleep $WAIT_AFTER_SUCCESSFUL_START
            wait_for_vm
        fi

        return $exit_code
    else
        return 1
    fi
}

# Function to kill the VM's KVM process
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
        if ps -p $VM_PID > /dev/null; then
            log_event "ERROR: Failed to kill KVM process $VM_PID."
            return 1
        else
            log_event "KVM process $VM_PID successfully killed."
            log_event "Attempting to start VM $FIREWALL_VMID."
            output=$(timeout $REMEDIATION_STEP_TIMEOUT /usr/sbin/qm start $FIREWALL_VMID 2>&1)
            exit_code=$?
            log_command_output "$output" "$exit_code" "/usr/sbin/qm start"

            if [ "$exit_code" -eq 0 ]; then
                log_event "VM $FIREWALL_VMID started successfully. Waiting for $WAIT_AFTER_SUCCESSFUL_START seconds before proceeding."
                sleep $WAIT_AFTER_SUCCESSFUL_START
                wait_for_vm
            fi

            return $exit_code
        fi
    fi
}

# Log the environment, user, and script ownership/permissions
log_event "Current PATH: $PATH"
log_event "Current User: $(whoami)"
log_event "Environment Variables: $(env)"
log_event "Script Owner: $(stat -c '%U' $0)"
log_event "Script Permissions: $(stat -c '%A' $0)"

# Main loop to monitor the firewall
attempt_counter=0
previous_failed=false

while true; do
    if check_firewall; then
        if [ "$previous_failed" = true ]; then
            log_event "Ping recovered successfully."
            previous_failed=false
        fi
        attempt_counter=0  # Reset counter if the ping is successful
    else
        previous_failed=true
        attempt_counter=$((attempt_counter + 1))
        log_event "Ping failed ($attempt_counter/$MAX_ATTEMPTS)"
    fi

    # If maximum ping failures reached, attempt to restart the firewall VM
    if [ $attempt_counter -ge $MAX_ATTEMPTS ]; then
        log_event "Firewall unresponsive for $((CHECK_INTERVAL * MAX_ATTEMPTS / 60)) minutes. Attempting to restart VM $FIREWALL_VMID."

        remediation_start_time=$(date +%s)
        remediation_end_time=$((remediation_start_time + HOST_REBOOT_TIMEOUT))
        vm_recovered=false
        
        while [ $(date +%s) -lt $remediation_end_time ]; do
            if reboot_vm && check_firewall; then
                log_event "Firewall is responsive. Stopping further remediation."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5  # Short delay before trying the next step

            if reset_vm && check_firewall; then
                log_event "Firewall is responsive. Stopping further remediation."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5  # Short delay before trying the next step

            if stop_and_start_vm && check_firewall; then
                log_event "Firewall is responsive. Stopping further remediation."
                vm_recovered=true
                previous_failed=false
                break
            fi
            sleep 5  # Short delay before trying the next step

            if kill_vm_process && check_firewall; then
                log_event "Firewall is responsive. Stopping further remediation."
                vm_recovered=true
                previous_failed=false
                break
            fi

            log_event "Remediation attempt failed. Will retry until the 15-minute timeout is reached."
        done

        if [ "$vm_recovered" = true ]; then
            log_event "VM $FIREWALL_VMID recovered successfully."
            attempt_counter=0  # Reset counter if recovery is successful
        else
            log_event "All attempts to recover VM $FIREWALL_VMID failed after 15 minutes. Rebooting the host."
            for vmid in $(/usr/sbin/qm list | awk '{print $1}' | grep -v VMID); do
                /usr/sbin/qm stop $vmid
                /usr/sbin/qm wait $vmid
            done
            log_event "Rebooting the host forcefully."
            reboot -f
        fi
    fi

    # Wait for the next check
    sleep $CHECK_INTERVAL
done
