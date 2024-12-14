#!/bin/bash

################################################################################
# Ceph LVM Remediation Script
#
# Description:
#   This script is designed to remediate Logical Volume Manager (LVM) and device
#   issues associated with Ceph OSDs (Object Storage Daemons). It automates the
#   cleanup and reinitialization of specified block devices to ensure they are
#   properly prepared for use in the Ceph cluster.
#
# Features:
#   - Lists available block devices for user reference.
#   - Prompts the user to input block devices that require remediation.
#   - Attempts to zap each specified device using `ceph-volume lvm zap`.
#   - If zapping fails, performs manual cleanup which includes:
#       - Identifying and removing associated Volume Groups (VGs).
#       - Deactivating and removing Logical Volumes (LVs).
#       - Removing Physical Volume (PV) labels.
#       - Handling encrypted LVs by closing LUKS mappings.
#       - Unmounting any mounted filesystems.
#       - Killing processes that are using the device mappings.
#       - Wiping filesystem signatures to ensure the device is clean.
#
# Logging:
#   All actions and their outcomes are logged to /var/log/ceph_lvm_remediate.log.
#   This log file provides a detailed record of the remediation process for
#   auditing and troubleshooting purposes.
#
# Usage:
#   1. Ensure the script has execute permissions:
#        chmod +x ceph_lvm_remediate.sh
#
#   2. Run the script as root:
#        sudo ./ceph_lvm_remediate.sh
#
#   3. Follow the on-screen prompts to enter the block devices you wish to remediate.
#
# Requirements:
#   - Must be run with root privileges.
#   - Ceph CLI tools (`ceph`, `ceph-volume`) must be installed and accessible.
#   - Utilities such as `lsblk`, `pvs`, `lvs`, `vgremove`, `lvremove`, `pvremove`,
#     `cryptsetup`, `lsof`, `umount`, and `wipefs` must be available on the system.
#
# Caution:
#   - This script performs destructive operations on the specified devices.
#     Ensure that you have selected the correct devices to avoid unintended data loss.
#   - Verify that the devices are not in use by other applications or services.
#
################################################################################

LOGFILE="/var/log/ceph_lvm_remediate.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOGFILE}"
}

run_cmd() {
    CMD="$1"
    log "Running: $CMD"
    if ! eval "$CMD"; then
        log "ERROR: Command failed: $CMD"
        log "Please check the command output above for details."
        return 1
    fi
    return 0
}

zap_disk() {
    device=$1
    log "Attempting to zap the disk: $device"
    if run_cmd "ceph-volume lvm zap $device --destroy"; then
        log "Zapping successful for $device"
    else
        log "Zapping failed for $device, proceeding with manual cleanup"
        return 1
    fi
    return 0
}

remediate_lvm() {
    echo "Available block devices:"
    lsblk -nd -o NAME,SIZE

    read -p "Enter the block devices to remediate (e.g., sda sdb sdc): " -a disks

    for disk in "${disks[@]}"; do
        device="/dev/$disk"
        
        # Attempt to zap the disk first
        if zap_disk "$device"; then
            continue
        fi

        log "Manual cleanup for LVM data from $device"

        VG_NAME=$(pvs --noheadings -o vg_name "$device" | tr -d ' ')
        if [ -n "$VG_NAME" ]; then
            # Get the LV name
            LV_NAME=$(lvs --noheadings -o lv_name "$VG_NAME" | tr -d ' ')
            LV_PATH="/dev/$VG_NAME/$LV_NAME"

            # Check if the LV is encrypted (LUKS)
            if cryptsetup isLuks "$LV_PATH" 2>/dev/null; then
                log "LV $LV_PATH is encrypted with LUKS."
                MAPPING_NAME=$(lsblk -ln -o NAME "$LV_PATH" | tail -n1)
                
                # Unmount any filesystems
                MOUNT_POINTS=$(mount | grep "$MAPPING_NAME" | awk '{print $3}')
                for MOUNT_POINT in $MOUNT_POINTS; do
                    log "Unmounting $MOUNT_POINT"
                    run_cmd "umount $MOUNT_POINT"
                done

                # Kill any processes using the mapping
                PIDS=$(lsof | grep "$MAPPING_NAME" | awk '{print $2}' | sort -u)
                if [ -n "$PIDS" ]; then
                    log "Killing processes using the mapping: $PIDS"
                    run_cmd "kill -9 $PIDS"
                fi

                log "Closing LUKS mapping $MAPPING_NAME"
                run_cmd "cryptsetup luksClose $MAPPING_NAME"
            fi

            # Deactivate and remove the LV
            run_cmd "lvchange -an --force $LV_PATH"
            run_cmd "lvremove -f $LV_PATH"

            # Remove the volume group
            run_cmd "vgremove -f $VG_NAME"

            # Remove the physical volume
            run_cmd "pvremove -ff -y $device"
        fi

        # Wipe filesystem signatures
        run_cmd "wipefs -a $device"
    done

    log "LVM remediation completed."
}

remediate_lvm
