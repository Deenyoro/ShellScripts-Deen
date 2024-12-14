#!/bin/bash

################################################################################
# Ceph OSD and Pool Management Script with Cephx Support and Sequential Steps.  #
# This script will guide you through a Ceph cluster setup process.              #
# It will NOT immediately run commands. Instead, it will compile a list of      #
# commands as you go through various steps. In the                              #
# end, you will have the option to review these commands and choose whether to  #
# execute them now or save them to a file for later execution.                  #
################################################################################

# Default settings
DEFAULT_COMPRESSION_ALGO="zstd"
DEFAULT_COMPRESSION_MODE="passive"
DEFAULT_AUTOSCALE_MODE="on"
DEFAULT_PG_TARGET_PER_OSD=100  # Target PGs per OSD
LOGFILE="/var/log/ceph_setup_commands.log"

# Array to hold all queued commands
COMMANDS=()

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOGFILE}"
}

# Utility function to confirm steps
confirm_step() {
    MSG="$1"
    echo "$MSG (y/n)"
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        log "User chose not to proceed with: $MSG"
        return 1
    else
        log "User confirmed: $MSG"
        return 0
    fi
}

# Add a command to the COMMANDS array
add_cmd() {
    CMD="$1"
    COMMANDS+=("$CMD")
    log "Queued command: $CMD"
}

# List available block devices for user reference
list_block_devices() {
    echo "---------------------------------------"
    echo "Available block devices:"
    lsblk -nd -o NAME,SIZE
    echo "---------------------------------------"
}

# Step 1: Prepare OSDs and Assign Device Classes
prepare_osds() {
    echo "---------------------------------------"
    echo "Step 1: Prepare OSDs and Assign Device Classes"
    echo "---------------------------------------"

    list_block_devices
    echo "Please enter the devices for the first device class configuration."
    read -p "Enter space-separated device names (e.g., sda sdb sdc): " OSD_DEVICES
    read -p "Enter the CRUSH Device Class for these devices: " DEVICE_CLASS

    if [ -z "$OSD_DEVICES" ] || [ -z "$DEVICE_CLASS" ]; then
        echo "You must provide both devices and a device class."
        return
    fi

    # Confirm zapping devices
    echo "You are about to zap these devices: $OSD_DEVICES"
    if ! confirm_step "Zapping will DESTROY all data on these devices. Proceed?"; then
        return
    fi

    # Add commands for zapping and creating OSDs
    for disk in $OSD_DEVICES; do
        add_cmd "ceph-volume lvm zap --destroy /dev/$disk"
        add_cmd "ceph-volume lvm create --data /dev/$disk --dmcrypt --crush-device-class $DEVICE_CLASS"
    done

    echo
    echo "You can repeat this step for other classes/devices if you have more sets of devices."
    echo "If you do, run this step again from the menu. Otherwise, move on."
    echo
}

# Step 2: Create CRUSH Rules and Erasure Code Profile
create_crush_and_ec() {
    echo "---------------------------------------"
    echo "Step 2: Create CRUSH Rules and Erasure Code Profile"
    echo "---------------------------------------"

    echo "You can create replicated CRUSH rules for different device classes."
    read -p "Enter the name of a replicated rule (e.g. replicated_myclass): " REPL_RULE_NAME
    read -p "Enter the device class for this rule (e.g. myclass): " REPL_DEVICE_CLASS

    if [ -n "$REPL_RULE_NAME" ] && [ -n "$REPL_DEVICE_CLASS" ]; then
        add_cmd "ceph osd crush rule create-replicated $REPL_RULE_NAME default host $REPL_DEVICE_CLASS"
    else
        echo "Skipping replicated rule creation due to missing inputs."
    fi

    echo
    echo "Now, if you want to create an erasure code profile and its corresponding CRUSH rule:"
    read -p "Enter an Erasure Code Profile name (e.g. myecprofile) or leave blank to skip: " EC_PROFILE
    if [ -n "$EC_PROFILE" ]; then
        read -p "Enter k (data chunks): " EC_K
        read -p "Enter m (parity chunks): " EC_M
        read -p "Enter device class for EC (e.g., myclass or blank): " EC_DEVICE_CLASS
        read -p "Enter failure domain (e.g. host): " EC_FAILURE_DOMAIN

        # Set defaults if needed
        EC_DEVICE_CLASS=${EC_DEVICE_CLASS:-none}
        if [ -z "$EC_FAILURE_DOMAIN" ]; then
            EC_FAILURE_DOMAIN="host"
        fi

        # Construct EC profile command
        if [ "$EC_DEVICE_CLASS" != "none" ]; then
            add_cmd "ceph osd erasure-code-profile set $EC_PROFILE k=$EC_K m=$EC_M crush-failure-domain=$EC_FAILURE_DOMAIN crush-device-class=$EC_DEVICE_CLASS"
        else
            add_cmd "ceph osd erasure-code-profile set $EC_PROFILE k=$EC_K m=$EC_M crush-failure-domain=$EC_FAILURE_DOMAIN"
        fi

        # Create EC crush rule
        read -p "Enter a CRUSH rule name for the EC profile (e.g. ec_myecprofile_rule): " EC_RULE_NAME
        if [ -n "$EC_RULE_NAME" ]; then
            add_cmd "ceph osd crush rule create-erasure $EC_RULE_NAME $EC_PROFILE"
        fi
    fi
}

# Step 3: Create Pools
create_pools() {
    echo "---------------------------------------"
    echo "Step 3: Create Pools"
    echo "---------------------------------------"

    echo "You can create multiple pools here. For each pool:"
    while true; do
        read -p "Enter a pool name (or blank to finish): " POOL_NAME
        if [ -z "$POOL_NAME" ]; then
            break
        fi

        echo "Pool Types:"
        echo "1) Replicated"
        echo "2) Erasure Coded"
        read -p "Enter pool type (1 or 2): " POOL_TYPE

        read -p "Enter the rule name for this pool (e.g. replicated_myclass or ec_myecprofile_rule): " POOL_RULE
        read -p "Enter pg_num: " PG_NUM
        read -p "Enter pgp_num (often same as pg_num): " PGP_NUM
        PGP_NUM=${PGP_NUM:-$PG_NUM}

        if [ "$POOL_TYPE" = "1" ]; then
            # Replicated pool
            add_cmd "ceph osd pool create $POOL_NAME $PG_NUM $PGP_NUM replicated $POOL_RULE"
            # Set replication size
            read -p "Enter replication size (e.g. 3): " SIZE
            if [ -n "$SIZE" ]; then
                add_cmd "ceph osd pool set $POOL_NAME size $SIZE"
            fi
        else
            # Erasure-coded pool
            add_cmd "ceph osd pool create $POOL_NAME $PG_NUM $PGP_NUM erasure $POOL_RULE"
            # For EC pool, we may want to allow overwrites and set a crush_rule if needed
            read -p "Allow EC overwrites? (y/n): " EC_OW
            if [[ "$EC_OW" =~ ^[Yy]$ ]]; then
                add_cmd "ceph osd pool set $POOL_NAME allow_ec_overwrites true"
            fi
            # If a different crush_rule should be set explicitly:
            echo "If the erasure-coded rule differs, set it now (or leave blank):"
            read -p "Enter crush_rule name for EC pool (or blank to skip): " EC_CRUSH_RULE
            if [ -n "$EC_CRUSH_RULE" ]; then
                add_cmd "ceph osd pool set $POOL_NAME crush_rule $EC_CRUSH_RULE"
            fi
        fi

        # Set application
        echo "Set application for the pool:"
        echo "Typical options: cephfs, rbd, mgr"
        read -p "Enter application name (e.g. cephfs, rbd, mgr) or leave blank: " APP
        if [ -n "$APP" ]; then
            add_cmd "ceph osd pool application enable $POOL_NAME $APP"
        fi

        echo "Pool $POOL_NAME configured. You can add another pool or leave blank to finish."
    done
}

# Step 4: Create CephFS Filesystems
create_cephfs_filesystems() {
    echo "---------------------------------------"
    echo "Step 4: Create CephFS Filesystems"
    echo "---------------------------------------"

    echo "You can create CephFS by specifying a metadata pool and a data pool."
    echo "Optionally, you can add additional data pools later."
    while true; do
        read -p "Enter a CephFS name (or blank to finish): " FS_NAME
        if [ -z "$FS_NAME" ]; then
            break
        fi
        read -p "Enter metadata pool for $FS_NAME: " META_POOL
        read -p "Enter data pool for $FS_NAME: " DATA_POOL

        if [ -n "$FS_NAME" ] && [ -n "$META_POOL" ] && [ -n "$DATA_POOL" ]; then
            add_cmd "ceph fs new $FS_NAME $META_POOL $DATA_POOL"
            echo "CephFS $FS_NAME created. If you want to add an additional data pool:"
            read -p "Enter an additional data pool name to add to $FS_NAME (or blank to skip): " EXTRA_POOL
            if [ -n "$EXTRA_POOL" ]; then
                add_cmd "ceph fs add_data_pool $FS_NAME $EXTRA_POOL"
            fi
        else
            echo "Skipping filesystem creation due to missing info."
        fi
    done
}

# Step 5: Set Pool Properties (Optional)
set_pool_properties() {
    echo "---------------------------------------"
    echo "Step 5: Set Pool Properties"
    echo "---------------------------------------"
    echo "You can set 'bulk' flag, pg_autoscale_mode, etc., on any pool."

    while true; do
        read -p "Enter a pool name to configure (or blank to finish): " P_NAME
        if [ -z "$P_NAME" ]; then
            break
        fi
        echo "Options for $P_NAME:"
        echo "1) Set 'bulk' flag"
        echo "2) Set pg_autoscale_mode"
        echo "3) Set compression_algorithm"
        echo "4) Set compression_mode"
        echo "5) Set size"
        echo "6) Done with this pool"
        while true; do
            read -p "Choose an option (1-6): " PROP_CHOICE
            case $PROP_CHOICE in
                1)
                    read -p "Set bulk to 'true' or 'false': " BULK_VAL
                    add_cmd "ceph osd pool set $P_NAME bulk $BULK_VAL"
                    ;;
                2)
                    read -p "Set pg_autoscale_mode (on/off/warn): " AUTO_VAL
                    add_cmd "ceph osd pool set $P_NAME pg_autoscale_mode $AUTO_VAL"
                    ;;
                3)
                    read -p "Set compression_algorithm (none/zstd/lz4/zlib): " CALGO
                    add_cmd "ceph osd pool set $P_NAME compression_algorithm $CALGO"
                    ;;
                4)
                    read -p "Set compression_mode (none/passive/aggressive/force): " CMODE
                    add_cmd "ceph osd pool set $P_NAME compression_mode $CMODE"
                    ;;
                5)
                    read -p "Set replication size: " NEW_SIZE
                    add_cmd "ceph osd pool set $P_NAME size $NEW_SIZE"
                    ;;
                6)
                    break
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done
    done
}

# At the end, allow user to review and decide to run or save
review_and_execute() {
    echo "---------------------------------------"
    echo "Step 6: Review Commands"
    echo "---------------------------------------"
    echo "The following commands have been compiled:"
    for cmd in "${COMMANDS[@]}"; do
        echo "$cmd"
    done

    echo
    echo "Options:"
    echo "1) Execute all commands now"
    echo "2) Save commands to a file"
    echo "3) Exit without executing"
    read -p "Enter your choice: " FINAL_CHOICE

    case $FINAL_CHOICE in
        1)
            echo "Executing commands now..."
            for cmd in "${COMMANDS[@]}"; do
                echo "Running: $cmd"
                if ! eval "$cmd"; then
                    echo "Error executing: $cmd"
                    echo "Aborting execution."
                    exit 1
                fi
            done
            echo "All commands executed successfully."
            ;;
        2)
            read -p "Enter filename to save commands (e.g. ceph_setup.sh): " OUTFILE
            if [ -z "$OUTFILE" ]; then
                OUTFILE="ceph_setup_commands.sh"
            fi
            {
                echo "#!/bin/bash"
                echo "# Generated by Ceph Army Knife Setup Script"
                for cmd in "${COMMANDS[@]}"; do
                    echo "$cmd"
                done
            } > "$OUTFILE"
            chmod +x "$OUTFILE"
            echo "Commands saved to $OUTFILE."
            ;;
        3)
            echo "Exiting without execution."
            ;;
        *)
            echo "Invalid choice. Exiting without execution."
            ;;
    esac
}

# Additional functions (optional) for management tasks not related to the initial sequence
remove_osds() {
    echo "This function can help remove OSDs safely."
    echo "NOTE: This is not part of the initial guided sequence."
    read -p "Enter OSD IDs to remove (space-separated): " OSDs
    for osd_id in $OSDs; do
        add_cmd "ceph osd out osd.$osd_id"
        # In a real environment, you'd wait for rebalance, etc.
        add_cmd "systemctl stop ceph-osd@$osd_id"
        add_cmd "ceph osd crush remove osd.$osd_id"
        add_cmd "ceph auth del osd.$osd_id"
        add_cmd "ceph osd rm $osd_id"
        # LVM cleanup etc. would be added if desired
    done
    echo "OSD removal commands added to the list."
}

check_cluster_health() {
    echo "This will just add commands to check health."
    add_cmd "ceph -s"
    add_cmd "ceph health detail"
    echo "Cluster health check commands queued."
}

show_osd_device_mapping() {
    echo "This will just add a command to show device mappings."
    add_cmd "ceph-volume lvm list"
    echo "OSD device mapping command queued."
}

# Main menu for the sequential steps and additional functions
while true; do
    echo "------------------------------------------------------------------------------"
    echo "Ceph Setup Wizard - Main Menu - These Commands are not Immediately Executed"
    echo "------------------------------------------------------------------------------"
    echo "1. Step 1: Prepare OSDs and Assign Device Classes"
    echo "2. Step 2: Create CRUSH Rules and Erasure Code Profile"
    echo "3. Step 3: Create Pools"
    echo "4. Step 4: Create CephFS Filesystems"
    echo "5. Step 5: Set Pool Properties"
    echo "6. Step 6: Review Commands and Execute/Save"
    echo
    echo "Additional Management (Not part of the main sequence):"
    echo "7. Remove OSDs"
    echo "8. Check Cluster Health"
    echo "9. Show OSD to Device Mapping"
    echo
    echo "10. Exit"

    read -p "Enter your choice: " CHOICE
    case $CHOICE in
        1) prepare_osds ;;
        2) create_crush_and_ec ;;
        3) create_pools ;;
        4) create_cephfs_filesystems ;;
        5) set_pool_properties ;;
        6) review_and_execute ;;
        7) remove_osds ;;
        8) check_cluster_health ;;
        9) show_osd_device_mapping ;;
        10) 
            echo "Exiting. Commands remain in memory unless saved. Goodbye."
            exit 0
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac

    echo
    read -p "Press Enter to continue..."
done
