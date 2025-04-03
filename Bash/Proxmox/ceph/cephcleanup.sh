#!/bin/bash

################################################################################
# Ceph Cluster Cleanup Script                                                  #
#                                                                              #
# Description:                                                                 #
#   This script automates the safe removal of Ceph Pools and OSDs.            #
#   It implements best practices for data migration and cleanup,               #
#   ensuring all data is properly relocated before removing components.        #
#                                                                              #
# Features:                                                                    #
#   - Safely removes Ceph pools with proper confirmation                       #
#   - Proper OSD removal with staged approach (out, down, remove)              #
#   - Handles LVM cleanup and device wiping                                    #
#   - Supports batch operations for multiple OSDs                              #
#   - Works with Proxmox VE environments                                       #
#   - Implements proper wait states and health checks                          #
#   - Follows best practices for Ceph administration                           #
#                                                                              #
# Usage:                                                                       #
#   1. Run with root privileges:                                               #
#      sudo ./ceph_cleanup.sh                                                  #
#                                                                              #
#   2. Follow the on-screen prompts to select operations and confirm actions   #
#                                                                              #
# Caution:                                                                     #
#   - This script performs destructive operations. Use with care!              #
#   - Always ensure you have proper backups before removing pools              #
#   - Verify you are targeting the correct OSDs/pools before proceeding        #
#                                                                              #
################################################################################

# Default settings
LOGFILE="/var/log/ceph_cleanup.log"
CONFIRM_STRING="YES-I-UNDERSTAND-THIS-WILL-DESTROY-DATA"
POLL_INTERVAL=30  # seconds to wait between health checks

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Setup logging
if [ ! -d "$(dirname "$LOGFILE")" ]; then
    mkdir -p "$(dirname "$LOGFILE")"
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOGFILE}"
}

run_cmd() {
    CMD="$1"
    CONTINUE_ON_ERROR="${2:-false}"
    
    log "Running: $CMD"
    if ! eval "$CMD"; then
        log "ERROR: Command failed: $CMD"
        if [ "$CONTINUE_ON_ERROR" != "true" ]; then
            log "Aborting due to command failure. Check the log for details."
            exit 1
        else
            log "Continuing despite command failure as requested."
        fi
        return 1
    fi
    return 0
}

confirm_action() {
    local MESSAGE="$1"
    local REQUIRED_CONFIRMATION="${2:-$CONFIRM_STRING}"
    
    echo ""
    echo "!!! WARNING !!!"
    echo "$MESSAGE"
    echo ""
    echo "This action cannot be undone and may result in DATA LOSS!"
    echo "To confirm, please type: $REQUIRED_CONFIRMATION"
    echo ""
    read -p "Confirmation: " confirmation
    
    if [ "$confirmation" != "$REQUIRED_CONFIRMATION" ]; then
        log "Action cancelled: Confirmation string did not match."
        return 1
    fi
    
    return 0
}

wait_for_cluster_health() {
    local TIMEOUT=${1:-1800}  # Default timeout 30 minutes
    local start_time=$(date +%s)
    local current_time
    
    log "Waiting for cluster to reach a clean state (timeout: $TIMEOUT seconds)..."
    
    while true; do
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $TIMEOUT ]; then
            log "WARNING: Timeout reached while waiting for cluster to become healthy."
            echo "Cluster health check timed out. Continue anyway? (y/n)"
            read -r continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                log "Operation aborted by user after timeout."
                return 1
            else
                log "User chose to continue despite timeout."
                return 0
            fi
        fi
        
        # Check cluster status
        local health_status=$(ceph health)
        local recovery_status=$(ceph -s | grep -E '(recovery|backfill|degraded|remapped)')
        
        if [[ "$health_status" == "HEALTH_OK" && -z "$recovery_status" ]]; then
            log "Cluster is healthy and all PGs are in a clean state."
            return 0
        elif [[ "$health_status" == *"HEALTH_WARN"* && ! "$recovery_status" ]]; then
            log "Cluster is in HEALTH_WARN state but no recovery operations in progress."
            echo "Cluster is in HEALTH_WARN state. Continue anyway? (y/n)"
            read -r continue_warn
            if [[ "$continue_warn" =~ ^[Yy]$ ]]; then
                log "User chose to continue with HEALTH_WARN status."
                return 0
            fi
        fi
        
        log "Cluster not yet healthy. Current status: $health_status"
        if [ -n "$recovery_status" ]; then
            log "Recovery in progress: $(echo "$recovery_status" | tr -d '\n')"
        fi
        
        echo "Waiting for cluster to stabilize... (Press Ctrl+C to cancel)"
        sleep $POLL_INTERVAL
    done
}

check_pool_usage() {
    local POOL_NAME="$1"
    
    # Check if the pool is used by RBD or virtual machines
    log "Checking if pool '$POOL_NAME' is used by RBD images or VMs..."
    
    # Check if Proxmox is installed and check for VMs
    if command -v pvesm &> /dev/null; then
        local STORAGE_USAGE=$(pvesm status | grep "$POOL_NAME")
        if [ -n "$STORAGE_USAGE" ]; then
            log "WARNING: Pool '$POOL_NAME' appears to be used as Proxmox storage:"
            echo "$STORAGE_USAGE"
            
            # Check for VMs using this storage
            local CONTENT_TYPES=$(pvesm status | grep "$POOL_NAME" | awk '{print $3}')
            if [[ "$CONTENT_TYPES" == *"images"* ]]; then
                log "Checking for VM disks on this storage..."
                local VM_LIST=$(qm list)
                if [ -n "$VM_LIST" ]; then
                    echo "The following VMs exist and might be using the storage:"
                    echo "$VM_LIST"
                    echo ""
                    echo "You must ensure no VMs are using this storage before removing the pool."
                fi
            fi
            
            echo "Do you want to continue checking for RBD images directly? (y/n)"
            read -r continue_check
            if [[ ! "$continue_check" =~ ^[Yy]$ ]]; then
                log "Pool usage check aborted by user."
                return 1
            fi
        fi
    fi
    
    # Check for RBD images in the pool
    local RBD_IMAGES=$(rbd -p "$POOL_NAME" ls 2>/dev/null)
    if [ -n "$RBD_IMAGES" ]; then
        log "WARNING: Found RBD images in pool '$POOL_NAME':"
        echo "$RBD_IMAGES"
        echo ""
        echo "These images must be removed or migrated before the pool can be deleted."
        return 1
    fi
    
    log "No RBD images found in pool '$POOL_NAME'."
    return 0
}

enable_pool_deletion() {
    log "Enabling pool deletion temporarily..."
    
    # Check current Ceph version to determine the proper command
    local CEPH_VERSION=$(ceph --version | grep -oP 'ceph version \K[0-9]+\.[0-9]+')
    local MAJOR_VERSION=$(echo $CEPH_VERSION | cut -d. -f1)
    
    if (( $(echo "$MAJOR_VERSION >= 14" | bc -l) )); then
        # Nautilus (14.x.x) and newer versions
        run_cmd "ceph config set mon mon_allow_pool_delete true"
    else
        # Legacy versions
        run_cmd "ceph tell mon.* injectargs --mon-allow-pool-delete=true"
    fi
    
    log "Pool deletion has been temporarily enabled."
}

disable_pool_deletion() {
    log "Disabling pool deletion for safety..."
    
    # Check current Ceph version to determine the proper command
    local CEPH_VERSION=$(ceph --version | grep -oP 'ceph version \K[0-9]+\.[0-9]+')
    local MAJOR_VERSION=$(echo $CEPH_VERSION | cut -d. -f1)
    
    if (( $(echo "$MAJOR_VERSION >= 14" | bc -l) )); then
        # Nautilus (14.x.x) and newer versions
        run_cmd "ceph config set mon mon_allow_pool_delete false"
    else
        # Legacy versions
        run_cmd "ceph tell mon.* injectargs --mon-allow-pool-delete=false"
    fi
    
    log "Pool deletion has been disabled."
}

# Function to remove a Ceph pool with proper safeguards
remove_pool() {
    log "Starting pool removal procedure..."
    
    # List all available pools
    local POOLS=$(ceph osd pool ls)
    if [ -z "$POOLS" ]; then
        log "No Ceph pools found."
        return 1
    fi
    
    echo "Available Ceph pools:"
    echo "---------------------"
    echo "$POOLS"
    echo "---------------------"
    
    read -p "Enter the name of the pool to remove: " POOL_NAME
    
    # Validate pool exists
    if ! echo "$POOLS" | grep -q "^$POOL_NAME$"; then
        log "ERROR: Pool '$POOL_NAME' does not exist."
        return 1
    fi
    
    # Check if the pool is used by RBD or VMs
    if ! check_pool_usage "$POOL_NAME"; then
        echo "Do you want to continue with pool removal despite usage warnings? (y/n)"
        read -r force_continue
        if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
            log "Pool removal aborted due to usage concerns."
            return 1
        fi
    fi
    
    # Final confirmation
    if ! confirm_action "You are about to DESTROY pool '$POOL_NAME' and ALL DATA in it."; then
        return 1
    fi
    
    # First check if pool is used as storage in Proxmox
    if command -v pvesm &> /dev/null; then
        local PVE_STORAGE=$(pvesm status | awk '{print $1}' | grep "^$POOL_NAME$")
        if [ -n "$PVE_STORAGE" ]; then
            log "Removing Proxmox storage configuration for '$POOL_NAME'..."
            run_cmd "pvesm remove $POOL_NAME"
        fi
    fi
    
    # Enable pool deletion
    enable_pool_deletion
    
    # Try to remove the pool
    log "Removing pool '$POOL_NAME'..."
    if ! run_cmd "ceph osd pool delete $POOL_NAME $POOL_NAME --yes-i-really-really-mean-it"; then
        log "ERROR: Failed to remove pool '$POOL_NAME'."
        disable_pool_deletion
        return 1
    fi
    
    # Disable pool deletion for safety
    disable_pool_deletion
    
    log "Pool '$POOL_NAME' has been successfully removed."
    return 0
}

# Function to remove Ceph OSDs with proper safeguards
remove_osds() {
    log "Starting OSD removal procedure..."
    
    # Show OSD tree
    echo "Current OSD Tree:"
    echo "----------------"
    ceph osd tree
    echo "----------------"
    
    read -p "Enter the OSD IDs to remove (space-separated, e.g., '0 1 2'): " -a OSD_IDS
    
    if [ ${#OSD_IDS[@]} -eq 0 ]; then
        log "No OSDs specified. Aborting."
        return 1
    fi
    
    # Confirmation
    echo "You have selected the following OSDs for removal:"
    for OSD_ID in "${OSD_IDS[@]}"; do
        echo "OSD.$OSD_ID"
    done
    
    if ! confirm_action "You are about to remove ${#OSD_IDS[@]} OSDs from your Ceph cluster."; then
        return 1
    fi
    
    # Build OSD to device mapping using ceph-volume lvm list
    declare -A OSD_DEVICE_MAP
    local CEPH_VOLUME_OUTPUT=$(ceph-volume lvm list 2>/dev/null)
    if [ $? -ne 0 ]; then
        log "Failed to execute 'ceph-volume lvm list'. Ensure Ceph is installed correctly."
        return 1
    fi
    
    # Parse the output to map OSD IDs to devices
    local CURRENT_OSD=""
    while IFS= read -r line; do
        # Detect the start of a new OSD block
        if [[ $line =~ ^=+[[:space:]]osd\.([0-9]+)[[:space:]]=+$ ]]; then
            CURRENT_OSD="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Extract the 'devices' field
        if [[ $line =~ ^[[:space:]]+devices[[:space:]]+(.+) ]]; then
            local DEVICE_PATH="${BASH_REMATCH[1]}"
            # Assign device to current_osd
            if [[ -n "$CURRENT_OSD" ]]; then
                OSD_DEVICE_MAP["$CURRENT_OSD"]="$DEVICE_PATH"
            fi
        fi
    done <<< "$CEPH_VOLUME_OUTPUT"
    
    # Process each OSD
    for OSD_ID in "${OSD_IDS[@]}"; do
        log "Processing OSD.$OSD_ID removal..."
        
        # Step 1: Mark the OSD out (stops sending data to it)
        log "Marking OSD.$OSD_ID out..."
        run_cmd "ceph osd out $OSD_ID"
        
        log "Waiting for data migration from OSD.$OSD_ID..."
        wait_for_cluster_health
        
        # Step 2: Stop the OSD daemon
        log "Stopping OSD.$OSD_ID daemon..."
        run_cmd "systemctl stop ceph-osd@$OSD_ID.service"
        
        # Step 3: Mark the OSD down if not already
        log "Marking OSD.$OSD_ID down..."
        run_cmd "ceph osd down $OSD_ID"
        
        # Step 4: Remove the OSD from the CRUSH map
        log "Removing OSD.$OSD_ID from CRUSH map..."
        run_cmd "ceph osd crush remove osd.$OSD_ID"
        
        # Step 5: Remove the OSD authentication key
        log "Removing authentication key for OSD.$OSD_ID..."
        run_cmd "ceph auth del osd.$OSD_ID"
        
        # Step 6: Remove the OSD from the OSD map
        log "Removing OSD.$OSD_ID from OSD map..."
        run_cmd "ceph osd rm $OSD_ID"
        
        # Step 7: Clean up LVM data if device is known
        if [ -n "${OSD_DEVICE_MAP[$OSD_ID]}" ]; then
            local DEVICE="${OSD_DEVICE_MAP[$OSD_ID]}"
            log "Cleaning up LVM data for OSD.$OSD_ID on device $DEVICE..."
            
            # Get volume group name
            local VG_NAME=$(pvs --noheadings -o vg_name $DEVICE 2>/dev/null | tr -d ' ')
            if [ -n "$VG_NAME" ]; then
                log "Found Volume Group $VG_NAME on $DEVICE"
                
                # Deactivate logical volumes in this VG
                local LV_PATHS=$(lvs --noheadings -o lv_path $VG_NAME 2>/dev/null | tr -d ' ')
                for lv_path in $LV_PATHS; do
                    if [ -n "$lv_path" ]; then
                        log "Deactivating logical volume: $lv_path"
                        run_cmd "lvchange -an $lv_path" true
                        
                        log "Removing logical volume: $lv_path"
                        run_cmd "lvremove -f $lv_path" true
                    fi
                done
                
                # Close any encrypted device mappings
                local DM_NAMES=$(dmsetup ls --target crypt 2>/dev/null | grep "$VG_NAME" | awk '{print $1}')
                for dm_name in $DM_NAMES; do
                    if [ -n "$dm_name" ]; then
                        log "Closing encrypted device mapping: $dm_name"
                        run_cmd "cryptsetup luksClose $dm_name" true
                    fi
                done
                
                # Check for open files on the VG
                local LSOF_OUTPUT=$(lsof 2>/dev/null | grep "$VG_NAME")
                if [ -n "$LSOF_OUTPUT" ]; then
                    log "Found open files/processes using $VG_NAME:"
                    echo "$LSOF_OUTPUT"
                    
                    local PIDS=$(echo "$LSOF_OUTPUT" | awk '{print $2}' | sort -u)
                    for pid in $PIDS; do
                        log "Killing process $pid"
                        run_cmd "kill -9 $pid" true
                    done
                fi
                
                # Deactivate the VG
                log "Deactivating VG $VG_NAME"
                run_cmd "vgchange -an $VG_NAME" true
                
                # Remove the VG
                log "Removing VG $VG_NAME"
                run_cmd "vgremove -f $VG_NAME" true
                
                # Remove the PV
                log "Removing PV label from $DEVICE"
                run_cmd "pvremove --force --force $DEVICE" true
            fi
            
            # Final zapping of the device to remove all traces
            log "Zapping $DEVICE..."
            run_cmd "wipefs -a $DEVICE" true
            
            if command -v ceph-volume &> /dev/null; then
                run_cmd "ceph-volume lvm zap --destroy $DEVICE" true
            fi
        else
            log "WARNING: Could not find device mapping for OSD.$OSD_ID. LVM cleanup may be incomplete."
        fi
        
        log "OSD.$OSD_ID has been removed successfully."
    done
    
    # Final health check after removing all specified OSDs
    log "Waiting for cluster to stabilize after OSD removal..."
    wait_for_cluster_health
    
    log "All specified OSDs have been removed successfully."
    return 0
}

# Function to do bare remediation of devices (similar to first script)
remediate_devices() {
    log "Starting device remediation procedure..."
    
    echo "Available block devices:"
    lsblk -nd -o NAME,SIZE
    
    read -p "Enter the block devices to remediate (e.g., sda sdb sdc): " -a DISKS
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        log "No devices specified. Aborting."
        return 1
    fi
    
    # Confirmation
    echo "You have selected the following devices for remediation:"
    for DISK in "${DISKS[@]}"; do
        echo "/dev/$DISK"
    done
    
    if ! confirm_action "You are about to wipe ${#DISKS[@]} devices completely."; then
        return 1
    fi
    
    for DISK in "${DISKS[@]}"; do
        DEVICE="/dev/$DISK"
        log "Processing device $DEVICE..."
        
        # Try to zap the disk first using ceph-volume
        if command -v ceph-volume &> /dev/null; then
            log "Attempting to zap disk using ceph-volume: $DEVICE"
            if run_cmd "ceph-volume lvm zap --destroy $DEVICE" true; then
                log "Successfully zapped $DEVICE using ceph-volume."
                continue
            else
                log "ceph-volume zap failed for $DEVICE, proceeding with manual cleanup."
            fi
        fi
        
        # Manual cleanup if ceph-volume fails or is not available
        log "Performing manual cleanup for $DEVICE..."
        
        # Check for LVM volume groups
        VG_NAME=$(pvs --noheadings -o vg_name $DEVICE 2>/dev/null | tr -d ' ')
        if [ -n "$VG_NAME" ]; then
            log "Found Volume Group $VG_NAME on $DEVICE"
            
            # Find logical volumes in this VG
            LV_NAMES=$(lvs --noheadings -o lv_name $VG_NAME 2>/dev/null | tr -d ' ')
            for LV_NAME in $LV_NAMES; do
                if [ -n "$LV_NAME" ]; then
                    LV_PATH="/dev/$VG_NAME/$LV_NAME"
                    
                    # Check if encrypted
                    if command -v cryptsetup &> /dev/null && cryptsetup isLuks "$LV_PATH" 2>/dev/null; then
                        log "LV $LV_PATH is encrypted with LUKS."
                        MAPPING_NAME=$(lsblk -ln -o NAME "$LV_PATH" 2>/dev/null | tail -n1)
                        
                        # Unmount any filesystems
                        MOUNT_POINTS=$(mount | grep "$MAPPING_NAME" | awk '{print $3}')
                        for MOUNT_POINT in $MOUNT_POINTS; do
                            log "Unmounting $MOUNT_POINT"
                            run_cmd "umount $MOUNT_POINT" true
                        done
                        
                        # Kill processes using the mapping
                        PIDS=$(lsof 2>/dev/null | grep "$MAPPING_NAME" | awk '{print $2}' | sort -u)
                        if [ -n "$PIDS" ]; then
                            log "Killing processes using the mapping: $PIDS"
                            for PID in $PIDS; do
                                run_cmd "kill -9 $PID" true
                            done
                        fi
                        
                        if [ -n "$MAPPING_NAME" ]; then
                            log "Closing LUKS mapping $MAPPING_NAME"
                            run_cmd "cryptsetup luksClose $MAPPING_NAME" true
                        fi
                    fi
                    
                    # Deactivate and remove LV
                    log "Deactivating logical volume: $LV_PATH"
                    run_cmd "lvchange -an --force $LV_PATH" true
                    
                    log "Removing logical volume: $LV_PATH"
                    run_cmd "lvremove -f $LV_PATH" true
                fi
            done
            
            # Remove the volume group
            log "Removing volume group: $VG_NAME"
            run_cmd "vgremove -f $VG_NAME" true
            
            # Remove the physical volume
            log "Removing physical volume label from $DEVICE"
            run_cmd "pvremove -ff -y $DEVICE" true
        fi
        
        # Wipe filesystem signatures
        log "Wiping all filesystem signatures from $DEVICE"
        run_cmd "wipefs -a $DEVICE" true
    done
    
    log "Device remediation completed successfully."
    return 0
}

# Function to purge Ceph completely from a host
purge_ceph() {
    log "Starting Ceph purge procedure..."
    
    # Confirmation with extra warnings
    if ! confirm_action "You are about to COMPLETELY PURGE Ceph from this host. All pools, OSDs, and configuration will be DESTROYED."; then
        return 1
    fi
    
    # Get hostname
    local HOSTNAME=$(hostname -s)
    
    # Check if this is a Proxmox host
    local IS_PROXMOX=false
    if command -v pveceph &> /dev/null; then
        IS_PROXMOX=true
        log "Detected Proxmox VE environment. Using Proxmox-specific commands."
    fi
    
    # Step 1: Check for active Ceph storages in Proxmox and warn user
    if $IS_PROXMOX; then
        local CEPH_STORAGES=$(pvesm status | grep -E 'rbd|cephfs')
        if [ -n "$CEPH_STORAGES" ]; then
            log "WARNING: Found active Ceph storages in Proxmox:"
            echo "$CEPH_STORAGES"
            echo ""
            echo "You must manually remove these storages first by moving all VMs/data"
            echo "to other storage and then removing the storage from Proxmox."
            echo ""
            echo "Do you want to continue anyway? This may leave your system in an inconsistent state! (y/n)"
            read -r force_continue
            if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
                log "Purge aborted due to active Ceph storages."
                return 1
            fi
        fi
    fi
    
    # Step 2: Stop all Ceph services
    log "Stopping all Ceph services..."
    run_cmd "systemctl stop ceph.target" true
    run_cmd "systemctl stop ceph-mon.target" true
    run_cmd "systemctl stop ceph-osd.target" true
    run_cmd "systemctl stop ceph-mds.target" true
    run_cmd "systemctl stop ceph-mgr.target" true
    
    # Step 3: If Proxmox, use pveceph purge
    if $IS_PROXMOX; then
        log "Purging Ceph using Proxmox commands..."
        # Try to remove individual components first
        
        # Remove OSDs
        local OSD_LIST=$(ceph osd ls 2>/dev/null)
        for OSD_ID in $OSD_LIST; do
            log "Removing OSD.$OSD_ID via Proxmox..."
            run_cmd "pveceph osd destroy $OSD_ID --cleanup" true
        done
        
        # Remove monitors
        log "Removing Ceph monitor on this host..."
        run_cmd "pveceph mon destroy" true
        
        # Final purge
        log "Executing full Proxmox Ceph purge..."
        run_cmd "pveceph purge" true
    else
        # Standard Ceph purge process
        log "Purging Ceph using standard commands..."
        
        # Mark all OSDs down and out
        local OSD_LIST=$(ceph osd ls 2>/dev/null)
        for OSD_ID in $OSD_LIST; do
            log "Marking OSD.$OSD_ID out and down..."
            run_cmd "ceph osd out $OSD_ID" true
            run_cmd "ceph osd down $OSD_ID" true
        done
        
        # Remove OSDs from the cluster
        for OSD_ID in $OSD_LIST; do
            log "Removing OSD.$OSD_ID from the cluster..."
            run_cmd "ceph osd crush remove osd.$OSD_ID" true
            run_cmd "ceph auth del osd.$OSD_ID" true
            run_cmd "ceph osd rm $OSD_ID" true
        done
    fi
    
    # Step 4: Remove Ceph configuration files
    log "Removing Ceph configuration files..."
    run_cmd "rm -rf /etc/ceph/*" true
    run_cmd "rm -rf /var/lib/ceph/*/*" true
    run_cmd "rm -rf /var/log/ceph/*" true
    if $IS_PROXMOX; then
        run_cmd "rm -rf /etc/pve/ceph*" true
    fi
    
    # Step 5: Clean up system services
    log "Resetting system services..."
    run_cmd "systemctl daemon-reload" true
    run_cmd "systemctl reset-failed" true
    
    log "Ceph purge completed. You may need to reboot your system for all changes to take effect."
    return 0
}

# Main menu
show_menu() {
    echo ""
    echo "============================================="
    echo "            Ceph Cleanup Script              "
    echo "============================================="
    echo "1. Remove Ceph Pool"
    echo "2. Remove Ceph OSDs"
    echo "3. Remediate Devices (Wipe/Zap)"
    echo "4. Purge Ceph Completely (DANGER!)"
    echo "5. Show Cluster Status"
    echo "0. Exit"
    echo "============================================="
    echo ""
    
    read -p "Select an option: " choice
    return $choice
}

# Show cluster status
show_status() {
    echo "Ceph Cluster Status:"
    echo "------------------"
    ceph -s
    
    echo ""
    echo "OSD Tree:"
    echo "------------------"
    ceph osd tree
    
    echo ""
    echo "Pool List:"
    echo "------------------"
    ceph osd pool ls
    
    echo ""
    echo "Pool Details:"
    echo "------------------"
    ceph osd pool ls detail
    
    if command -v pvesm &> /dev/null; then
        echo ""
        echo "Proxmox Storage:"
        echo "------------------"
        pvesm status
    fi
    
    read -p "Press Enter to continue..."
    return 0
}

# Main program
log "Ceph Cleanup Script started."

while true; do
    show_menu
    choice=$?
    
    case $choice in
        1)
            remove_pool
            ;;
        2)
            remove_osds
            ;;
        3)
            remediate_devices
            ;;
        4)
            purge_ceph
            ;;
        5)
            show_status
            ;;
        0)
            echo "Exiting..."
            log "Ceph Cleanup Script completed."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done
