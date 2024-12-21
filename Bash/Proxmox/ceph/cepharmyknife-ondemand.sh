#!/bin/bash

################################################################################
# Ceph OSD and Pool Management Script with Cephx Support - These commands are  #
# executed immediately                                                         #
#                                                                              #
# This script will guide you through various Ceph cluster management tasks,    #
# including creating OSDs, pools, managing CephFS, configuring encryption,     #
# and managing CephX authentication. It provides detailed explanations and     #
# configurable options at each step, allowing you to customize settings or     #
# accept defaults by pressing Enter.                                           #
################################################################################

# Default settings
DEFAULT_CRUSH_CLASS="ssd"            # Default CRUSH device class
DEFAULT_COMPRESSION_ALGO="zstd"      # Default compression algorithm
DEFAULT_COMPRESSION_MODE="passive"   # Default compression mode
DEFAULT_AUTOSCALE_MODE="on"          # Default PG autoscaling mode
DEFAULT_PG_TARGET_PER_OSD=100        # Target PGs per OSD
DEFAULT_REPLICATION_SIZE=3           # Default replication size
LOGFILE="/var/log/ceph_osd_setup.log"

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Exiting."
    exit 1
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOGFILE}"
}

# Function to run a command and handle errors
run_cmd() {
    CMD="$1"
    CONTINUE_ON_ERROR="$2"
    log "Running: $CMD"
    if ! eval "$CMD"; then
        log "ERROR: Command failed: $CMD"
        log "Please check the command output above for details."
        if [ "$CONTINUE_ON_ERROR" != "true" ]; then
            exit 1
        fi
    fi
}

# Function to confirm a step with user input and log the response
confirm_step() {
    MSG="$1"
    echo "$MSG (y/n)"
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        log "User chose not to proceed with: $MSG"
        exit 0
    else
        log "User confirmed: $MSG"
    fi
}

# Function to list available pools
list_pools() {
    echo "---------------------------------------"
    echo "Available Pools:"
    ceph osd pool ls
    echo "---------------------------------------"
}

# Function to list available CRUSH device classes
list_crush_classes() {
    echo "---------------------------------------"
    echo "Available CRUSH Device Classes:"
    ceph osd crush class ls
    echo "---------------------------------------"
}

# Function to create OSDs
create_osds() {
    echo "---------------------------------------"
    echo "Welcome to the Ceph OSD Setup Script"
    echo "---------------------------------------"

    log "Script started."

    # Check initial cluster health
    log "Checking initial cluster health..."
    HEALTH_STATUS=$(ceph health)
    if [[ "$HEALTH_STATUS" != "HEALTH_OK" ]]; then
        log "WARNING: Cluster health is not OK: $HEALTH_STATUS"
        confirm_step "Do you still want to proceed?"
    fi

    echo "Available block devices:"
    lsblk -nd -o NAME,SIZE

    read -p "Enter the block devices to use (e.g., sda sdb sdc): " DISK_NAMES
    read -p "Enter the CRUSH Device Class [default: $DEFAULT_CRUSH_CLASS]: " CRUSH_CLASS_INPUT

    # Set variables based on user input or defaults
    CRUSH_CLASS="${CRUSH_CLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"

    # Ask for custom CRUSH location (optional)
    read -p "Enter the CRUSH location (e.g., root=default rack=rack1 host=host1) [leave blank for default]: " CRUSH_LOCATION_INPUT
    CRUSH_LOCATION="${CRUSH_LOCATION_INPUT}"

    # Display settings before proceeding
    echo "---------------------------------------"
    echo "You have selected:"
    echo "Block Devices: $DISK_NAMES"
    echo "CRUSH Device Class: $CRUSH_CLASS"
    if [ -n "$CRUSH_LOCATION" ]; then
        echo "Custom CRUSH Location: $CRUSH_LOCATION"
    else
        echo "CRUSH Location: Default"
    fi
    echo "---------------------------------------"

    confirm_step "Proceed with these settings?"

    # Prompt once to zap all devices
    echo "You are about to zap the following devices:"
    echo "$DISK_NAMES"
    confirm_step "This will erase all data on these devices. Do you want to proceed?"

    # Get the list of OSD IDs before creation
    BEFORE_OSD_IDS=$(ceph osd ls)

    # Process each disk
    for disk in $DISK_NAMES; do
        device="/dev/$disk"
        log "Processing $device..."

        # Deactivate any LVM volumes on the device
        VG_NAME=$(pvs --noheadings -o vg_name $device | tr -d ' ')
        if [ -n "$VG_NAME" ]; then
            log "LVM data found on $device. Wiping existing LVM data..."

            # Deactivate logical volumes
            LV_PATHS=$(lvs --noheadings -o lv_path $VG_NAME | tr -d ' ')
            for lv_path in $LV_PATHS; do
                echo "Deactivating logical volume: $lv_path"
                run_cmd "lvchange -an $lv_path"
                echo "Removing logical volume: $lv_path"
                run_cmd "lvremove -f $lv_path"
            done

            # Close any encrypted device mappings
            DM_NAMES=$(dmsetup ls --target crypt | grep "$VG_NAME" | awk '{print $1}')
            for dm_name in $DM_NAMES; do
                echo "Closing encrypted device mapping: $dm_name"
                run_cmd "cryptsetup luksClose $dm_name"
            done

            # Deactivate the VG
            echo "Deactivating VG $VG_NAME associated with $device"
            run_cmd "vgchange -an $VG_NAME"

            # Remove the VG
            echo "Removing VG $VG_NAME"
            run_cmd "vgremove -f $VG_NAME"

            # Remove the PV
            echo "Removing PV label from $device"
            run_cmd "pvremove --force --force $device"
        else
            log "No LVM data found on $device."
        fi

        # Zap the device
        log "Zapping $device..."
        run_cmd "ceph-volume lvm zap --destroy $device"

        log "Creating OSD on $device with encryption..."
        run_cmd "ceph-volume lvm create --data $device --dmcrypt --crush-device-class $CRUSH_CLASS"
    done

    # Get the list of OSD IDs after creation
    AFTER_OSD_IDS=$(ceph osd ls)

    # Determine the new OSD IDs
    NEW_OSD_IDS=$(comm -13 <(echo "$BEFORE_OSD_IDS" | sort) <(echo "$AFTER_OSD_IDS" | sort))

    # For each new OSD, perform necessary actions
    for OSD_ID in $NEW_OSD_IDS; do
        log "Processing new OSD ID: $OSD_ID"

        # Ensure the OSD service is started
        log "Starting OSD service for OSD.$OSD_ID..."
        run_cmd "systemctl start ceph-osd@$OSD_ID"

        # Set the device class explicitly
        log "Setting device class for OSD.$OSD_ID..."
        run_cmd "ceph osd crush set-device-class $CRUSH_CLASS osd.$OSD_ID"

        # Move the OSD to the custom CRUSH location if specified
        if [ -n "$CRUSH_LOCATION" ]; then
            log "Moving OSD.$OSD_ID to custom CRUSH location..."
            run_cmd "ceph osd crush move osd.$OSD_ID $CRUSH_LOCATION"
        fi
    done

    # Check cluster health after making changes
    log "Checking cluster health after adding OSDs..."
    ceph health detail | tee -a "${LOGFILE}"

    log "Ceph OSD setup completed successfully."
}

# Function to create pools (replicated or erasure-coded)
create_pool() {
    echo "---------------------------------------"
    echo "Ceph Pool Creation and Configuration"
    echo "---------------------------------------"

    # List available pools
    list_pools

    # List available CRUSH device classes
    list_crush_classes

    # Pool name input
    read -p "Enter the name for the pool: " POOL_NAME

    # Pool type selection: Replicated or Erasure Coded
    echo "Select pool type:"
    echo "1. Replicated"
    echo "2. Erasure Coded"
    read -p "Enter the pool type (1 or 2): " POOL_TYPE

    if [ "$POOL_TYPE" == "1" ]; then
        # Replicated Pool Creation

        # Read CRUSH Device Class
        read -p "Enter the CRUSH Device Class for the pool [default: $DEFAULT_CRUSH_CLASS]: " CRUSH_CLASS_INPUT
        CRUSH_CLASS="${CRUSH_CLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"

        # Set default pool name based on the CRUSH class
        DEFAULT_POOL_NAME="${CRUSH_CLASS}_pool"

        echo "---------------------------------------"
        echo "**Replication Size Overview:**"
        echo "- **What is Replication Size?**"
        echo "  The number of copies of each piece of data in the cluster."
        echo "- **Default Value:**"
        echo "  The default replication size is $DEFAULT_REPLICATION_SIZE, meaning each piece of data is stored on $DEFAULT_REPLICATION_SIZE OSDs."
        echo "- **Considerations:**"
        echo "  A higher replication size provides better data redundancy but uses more storage space."
        echo "---------------------------------------"

        read -p "Enter the replication size [default: $DEFAULT_REPLICATION_SIZE]: " REPLICATION_SIZE_INPUT
        REPLICATION_SIZE="${REPLICATION_SIZE_INPUT:-$DEFAULT_REPLICATION_SIZE}"

        # Calculate PG_NUM
        echo "---------------------------------------"
        echo "**Calculating Recommended Number of Placement Groups (PGs):**"
        echo "- **Formula Used:**"
        echo "  (Total Number of OSDs * Target PGs per OSD) / Replication Size"
        echo "- **Assumed Target PGs per OSD:** $DEFAULT_PG_TARGET_PER_OSD"
        NUM_OSDS=$(ceph osd ls | wc -l)
        echo "- **Total OSDs in the cluster:** $NUM_OSDS"
        echo "- **Replication Size:** $REPLICATION_SIZE"
        echo "---------------------------------------"

        RECOMMENDED_PG_NUM=$(( ($NUM_OSDS * $DEFAULT_PG_TARGET_PER_OSD) / $REPLICATION_SIZE ))

        PG_NUM=$(awk -v n=$RECOMMENDED_PG_NUM 'BEGIN{
            lower=2^int(log(n)/log(2));
            upper=2^(int(log(n)/log(2))+1);
            if ((n - lower) < (upper - n)) {
                print lower;
            } else {
                print upper;
            }
        }')

        echo "Based on your inputs, the recommended number of PGs is: $PG_NUM"
        echo "This is adjusted to the nearest power of 2 for optimal performance."

        echo "---------------------------------------"
        echo "**Placement Groups (PGs) Overview:**"
        echo "- **What is a PG?**"
        echo "  A PG (Placement Group) is a logical container for storing objects."
        echo "  PGs allow Ceph to efficiently manage and distribute data across OSDs."
        echo "- **Why is PG Number Important?**"
        echo "  The number of PGs affects the distribution of data across the cluster."
        echo "  Too few PGs can lead to uneven data distribution, while too many PGs"
        echo "  can cause excessive overhead and impact performance."
        echo "- **Recommendation:**"
        echo "  The script has calculated a recommended PG number based on your setup."
        echo "  You can accept this value or enter a custom value."
        echo "---------------------------------------"

        read -p "Enter the number of PGs [default: $PG_NUM]: " PG_NUM_INPUT
        PG_NUM="${PG_NUM_INPUT:-$PG_NUM}"

        # Compression settings
        echo "---------------------------------------"
        echo "**Compression Algorithm Options:**"
        echo "  - none: No compression"
        echo "  - lz4: Fast compression with lower compression ratios"
        echo "  - zlib: Higher compression ratio but slower"
        echo "  - zstd: High compression ratio and fast, recommended"
        echo "---------------------------------------"

        read -p "Enter the compression algorithm [default: $DEFAULT_COMPRESSION_ALGO]: " COMPRESSION_ALGO_INPUT

        echo "---------------------------------------"
        echo "**Compression Mode Options:**"
        echo "  - none: No compression"
        echo "  - passive: Compress only if compression results in space savings"
        echo "  - aggressive: Compress all data"
        echo "  - force: Force compression even if no space savings"
        echo "---------------------------------------"

        read -p "Enter the compression mode [default: $DEFAULT_COMPRESSION_MODE]: " COMPRESSION_MODE_INPUT

        echo "---------------------------------------"
        echo "**Autoscale Mode Options:**"
        echo "  - on: Automatically adjust PGs as the pool grows (recommended)"
        echo "  - off: No automatic adjustment"
        echo "  - warn: Warn when the pool is near PG limits"
        echo "---------------------------------------"

        read -p "Enter the autoscale mode [default: $DEFAULT_AUTOSCALE_MODE]: " AUTOSCALE_MODE_INPUT

        read -p "Create the CRUSH rule cluster-wide? (y/n) [default: y]: " CREATE_CRUSH_RULE_INPUT
        CREATE_CRUSH_RULE="${CREATE_CRUSH_RULE_INPUT:-y}"

        # Set variables based on user input or defaults
        COMPRESSION_ALGO="${COMPRESSION_ALGO_INPUT:-$DEFAULT_COMPRESSION_ALGO}"
        COMPRESSION_MODE="${COMPRESSION_MODE_INPUT:-$DEFAULT_COMPRESSION_MODE}"
        AUTOSCALE_MODE="${AUTOSCALE_MODE_INPUT:-$DEFAULT_AUTOSCALE_MODE}"

        # Display settings before proceeding
        echo "---------------------------------------"
        echo "You have selected:"
        echo "Pool Name: $POOL_NAME"
        echo "CRUSH Device Class: $CRUSH_CLASS"
        echo "Replication Size: $REPLICATION_SIZE"
        echo "Placement Groups (PGs): $PG_NUM"
        echo "Compression Algorithm: $COMPRESSION_ALGO"
        echo "Compression Mode: $COMPRESSION_MODE"
        echo "Autoscale Mode: $AUTOSCALE_MODE"
        echo "Create CRUSH rule cluster-wide: $CREATE_CRUSH_RULE"
        echo "---------------------------------------"

        confirm_step "Proceed with these settings?"

        # Create CRUSH rule if needed
        if [[ "$CREATE_CRUSH_RULE" =~ ^[Yy]$ ]]; then
            log "Creating CRUSH rule for pool..."
            run_cmd "ceph osd crush rule create-replicated ${POOL_NAME}_rule default host $CRUSH_CLASS"
        fi

        # Create replicated pool
        log "Creating pool with name $POOL_NAME and PG number $PG_NUM..."
        run_cmd "ceph osd pool create $POOL_NAME $PG_NUM $PG_NUM replicated ${POOL_NAME}_rule"

        log "Setting replication size to $REPLICATION_SIZE..."
        run_cmd "ceph osd pool set $POOL_NAME size $REPLICATION_SIZE"

        log "Setting compression algorithm to $COMPRESSION_ALGO..."
        run_cmd "ceph osd pool set $POOL_NAME compression_algorithm $COMPRESSION_ALGO"

        log "Setting compression mode to $COMPRESSION_MODE..."
        run_cmd "ceph osd pool set $POOL_NAME compression_mode $COMPRESSION_MODE"

        log "Setting autoscale mode to $AUTOSCALE_MODE..."
        run_cmd "ceph osd pool set $POOL_NAME pg_autoscale_mode $AUTOSCALE_MODE"

    elif [ "$POOL_TYPE" == "2" ]; then
        # Erasure Coded Pool Creation

        # Read CRUSH Device Class
        read -p "Enter the CRUSH Device Class for the pool [default: $DEFAULT_CRUSH_CLASS]: " CRUSH_CLASS_INPUT
        CRUSH_CLASS="${CRUSH_CLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"

        echo "---------------------------------------"
        echo "**Erasure Coding Overview:**"
        echo "- **What is Erasure Coding?**"
        echo "  A method of data protection that breaks data into fragments, expands and"
        echo "  encodes it with redundant data pieces, and stores it across different locations."
        echo "- **Parameters:**"
        echo "  - k (Data Chunks)"
        echo "  - m (Parity Chunks)"
        echo "  - crush-failure-domain (e.g., host, rack, etc.)"
        echo "---------------------------------------"

        read -p "Enter the number of data chunks (k) [default: 2]: " EC_DATA_CHUNKS_INPUT
        EC_DATA_CHUNKS="${EC_DATA_CHUNKS_INPUT:-2}"
        read -p "Enter the number of parity chunks (m) [default: 1]: " EC_PARITY_CHUNKS_INPUT
        EC_PARITY_CHUNKS="${EC_PARITY_CHUNKS_INPUT:-1}"
        read -p "Enter the crush-failure-domain [default: host]: " EC_FAILURE_DOMAIN_INPUT
        EC_FAILURE_DOMAIN="${EC_FAILURE_DOMAIN_INPUT:-host}"

        # Calculate PG_NUM
        echo "---------------------------------------"
        echo "**Calculating Recommended Number of Placement Groups (PGs):**"
        echo "- **Formula Used:**"
        echo "  (Total Number of OSDs * Target PGs per OSD) / (k + m)"
        echo "- **Assumed Target PGs per OSD:** $DEFAULT_PG_TARGET_PER_OSD"
        NUM_OSDS=$(ceph osd ls | wc -l)
        TOTAL_CHUNKS=$(($EC_DATA_CHUNKS + $EC_PARITY_CHUNKS))
        echo "- **Total OSDs in the cluster:** $NUM_OSDS"
        echo "- **Erasure Coding Parameters:** k=$EC_DATA_CHUNKS, m=$EC_PARITY_CHUNKS"
        echo "---------------------------------------"

        RECOMMENDED_PG_NUM=$(( ($NUM_OSDS * $DEFAULT_PG_TARGET_PER_OSD) / $TOTAL_CHUNKS ))

        PG_NUM=$(awk -v n=$RECOMMENDED_PG_NUM 'BEGIN{
            lower=2^int(log(n)/log(2));
            upper=2^(int(log(n)/log(2))+1);
            if ((n - lower) < (upper - n)) {
                print lower;
            } else {
                print upper;
            }
        }')

        echo "Based on your inputs, the recommended number of PGs is: $PG_NUM"
        echo "This is adjusted to the nearest power of 2 for optimal performance."

        read -p "Enter the number of PGs [default: $PG_NUM]: " PG_NUM_INPUT
        PG_NUM="${PG_NUM_INPUT:-$PG_NUM}"

        echo "---------------------------------------"
        echo "**Autoscale Mode Options:**"
        echo "  - on: Automatically adjust PGs as the pool grows (recommended)"
        echo "  - off: No automatic adjustment"
        echo "  - warn: Warn when the pool is near PG limits"
        echo "---------------------------------------"

        read -p "Enter the autoscale mode [default: $DEFAULT_AUTOSCALE_MODE]: " AUTOSCALE_MODE_INPUT
        AUTOSCALE_MODE="${AUTOSCALE_MODE_INPUT:-$DEFAULT_AUTOSCALE_MODE}"

        log "Creating erasure code profile..."
        run_cmd "ceph osd erasure-code-profile set ${POOL_NAME}_ecprofile k=$EC_DATA_CHUNKS m=$EC_PARITY_CHUNKS crush-device-class=$CRUSH_CLASS crush-failure-domain=$EC_FAILURE_DOMAIN"

        log "Creating CRUSH rule for erasure-coded pool..."
        run_cmd "ceph osd crush rule create-erasure ${POOL_NAME}_erasure_rule ${POOL_NAME}_ecprofile"

        log "Creating erasure-coded pool..."
        run_cmd "ceph osd pool create $POOL_NAME $PG_NUM $PG_NUM erasure ${POOL_NAME}_erasure_rule"

        log "Setting autoscale mode to $AUTOSCALE_MODE..."
        run_cmd "ceph osd pool set $POOL_NAME pg_autoscale_mode $AUTOSCALE_MODE"

        read -p "Allow overwrites on erasure-coded pool? (y/n) [default: n]: " ALLOW_EC_OVERWRITES_INPUT
        ALLOW_EC_OVERWRITES="${ALLOW_EC_OVERWRITES_INPUT:-n}"
        if [[ "$ALLOW_EC_OVERWRITES" =~ ^[Yy]$ ]]; then
            log "Setting allow_ec_overwrites to true..."
            run_cmd "ceph osd pool set $POOL_NAME allow_ec_overwrites true"
        fi

    else
        echo "Invalid pool type selection. Exiting."
        exit 1
    fi

    # Check cluster health after making changes
    log "Checking cluster health after creating pool..."
    ceph health detail | tee -a "${LOGFILE}"

    log "Ceph pool creation completed successfully."
}

# Function to create a metadata pool on SSDs
create_metadata_pool() {
    echo "---------------------------------------"
    echo "Metadata Pool Creation on SSDs"
    echo "---------------------------------------"

    # List available CRUSH classes
    list_crush_classes

    # Pool name input
    read -p "Enter the name for the metadata pool: " METADATA_POOL_NAME

    # Read CRUSH Device Class for SSDs
    read -p "Enter the CRUSH Device Class for SSDs [default: $DEFAULT_CRUSH_CLASS]: " SSD_CRUSH_CLASS_INPUT
    SSD_CRUSH_CLASS="${SSD_CRUSH_CLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"

    # Replication size for metadata pool
    echo "---------------------------------------"
    echo "**Metadata Pool Replication Size Overview:**"
    echo "- **Default Replication Size:** $DEFAULT_REPLICATION_SIZE"
    echo "---------------------------------------"

    read -p "Enter the replication size for the metadata pool [default: $DEFAULT_REPLICATION_SIZE]: " META_REPLICATION_SIZE_INPUT
    META_REPLICATION_SIZE="${META_REPLICATION_SIZE_INPUT:-$DEFAULT_REPLICATION_SIZE}"

    # Calculate PG_NUM
    echo "Calculating PG_NUM for metadata pool..."
    NUM_OSDS=$(ceph osd crush class ls-osd $SSD_CRUSH_CLASS | wc -l)
    if [ "$NUM_OSDS" -eq 0 ]; then
        echo "No OSDs found with device class $SSD_CRUSH_CLASS."
        read -p "Enter the total number of OSDs planned for this device class: " NUM_OSDS_INPUT
        NUM_OSDS="${NUM_OSDS_INPUT:-1}"
    fi
    RECOMMENDED_PG_NUM=$(( ($NUM_OSDS * $DEFAULT_PG_TARGET_PER_OSD) / $META_REPLICATION_SIZE ))
    PG_NUM=$(awk -v n=$RECOMMENDED_PG_NUM 'BEGIN{
        lower=2^int(log(n)/log(2));
        upper=2^(int(log(n)/log(2))+1);
        if ((n - lower) < (upper - n)) {
            print lower;
        } else {
            print upper;
        }
    }')
    echo "Recommended PG_NUM for metadata pool: $PG_NUM"

    read -p "Enter the number of PGs for the metadata pool [default: $PG_NUM]: " META_PG_NUM_INPUT
    META_PG_NUM="${META_PG_NUM_INPUT:-$PG_NUM}"

    log "Creating CRUSH rule for metadata pool..."
    run_cmd "ceph osd crush rule create-replicated ${METADATA_POOL_NAME}_rule default host $SSD_CRUSH_CLASS"

    log "Creating metadata pool on SSDs..."
    run_cmd "ceph osd pool create $METADATA_POOL_NAME $META_PG_NUM $META_PG_NUM replicated ${METADATA_POOL_NAME}_rule"

    log "Setting replication size for metadata pool..."
    run_cmd "ceph osd pool set $METADATA_POOL_NAME size $META_REPLICATION_SIZE"

    log "Setting autoscale mode to $DEFAULT_AUTOSCALE_MODE..."
    run_cmd "ceph osd pool set $METADATA_POOL_NAME pg_autoscale_mode $DEFAULT_AUTOSCALE_MODE"

    log "Checking cluster health after creating metadata pool..."
    ceph health detail | tee -a "${LOGFILE}"

    log "Metadata pool creation completed successfully."
}

# Function to remove OSDs safely with LVM cleanup
remove_osds() {
    echo "Listing all known OSDs and their status..."
    ceph osd tree

    read -p "Enter the OSD IDs you want to remove, separated by spaces: " -a osd_ids

    echo "You entered the following OSD IDs: ${osd_ids[@]}"
    read -p "Are you sure you want to proceed with removing these OSDs? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborting the operation."
        exit 1
    fi

    existing_osds=$(ceph osd ls)

    for osd_id in "${osd_ids[@]}"; do
        echo "Processing OSD ID: $osd_id"

        ceph osd out osd.${osd_id}
        echo "OSD.${osd_id} marked out."

        echo "Waiting for data to rebalance..."
        while true; do
            HEALTH=$(ceph health detail)
            if ! echo "$HEALTH" | grep -qE "(recovery|degraded|backfill)"; then
                echo "Data rebalanced."
                break
            else
                echo "Cluster is rebalancing. Waiting..."
                sleep 30
            fi
        done

        echo "Stopping OSD service for OSD.${osd_id}"
        systemctl stop ceph-osd@${osd_id}

        ceph osd crush remove osd.${osd_id}
        echo "Removed OSD.${osd_id} from the CRUSH map."

        ceph auth del osd.${osd_id}
        echo "Deleted authentication key for OSD.${osd_id}."

        ceph osd rm ${osd_id}
        echo "Removed OSD.${osd_id} from the OSD map."

        echo "OSD ID: $osd_id has been removed successfully."

        echo "Cleaning up LVM data for OSD.${osd_id}..."
        OSD_DATA_PATH="/var/lib/ceph/osd/ceph-${osd_id}"
        if [ -d "$OSD_DATA_PATH" ]; then
            DEVICE=$(readlink -f $OSD_DATA_PATH/block)
            if [ -n "$DEVICE" ]; then
                DM_NAME=$(basename "$DEVICE")
                # Check if the device mapping exists before attempting to close it
                if dmsetup ls --target crypt | grep -qw "$DM_NAME"; then
                    echo "Closing encrypted device mapping: $DM_NAME"
                    run_cmd "cryptsetup luksClose $DM_NAME" "true"
                else
                    echo "Encrypted device mapping $DM_NAME is not active, skipping."
                fi

                LV_PATH=$(lvdisplay | grep -B1 "$DEVICE" | grep "LV Path" | awk '{print $3}')
                if [ -n "$LV_PATH" ]; then
                    echo "Deactivating logical volume: $LV_PATH"
                    run_cmd "lvchange -an $LV_PATH" "true"
                    echo "Removing logical volume: $LV_PATH"
                    run_cmd "lvremove -f $LV_PATH" "true"
                else
                    echo "Could not find logical volume for $DEVICE or it has already been removed."
                fi

                VG_NAME=$(pvs --noheadings -o vg_name $DEVICE | tr -d ' ')
                if [ -n "$VG_NAME" ]; then
                    echo "Deactivating VG $VG_NAME associated with $DEVICE"
                    run_cmd "vgchange -an $VG_NAME" "true"
                    echo "Removing VG $VG_NAME"
                    run_cmd "vgremove -f $VG_NAME" "true"
                else
                    echo "Could not find volume group for $DEVICE or it has already been removed."
                fi

                echo "Removing PV label from $DEVICE"
                run_cmd "pvremove --force --force $DEVICE" "true"

                echo "Zapping $DEVICE..."
                run_cmd "ceph-volume lvm zap --destroy $DEVICE" "true"
            else
                echo "Could not find block device for OSD.${osd_id}. Skipping LVM cleanup."
            fi
        else
            echo "OSD data path $OSD_DATA_PATH does not exist. Skipping LVM cleanup."
        fi
    done

    echo "All specified OSDs have been processed."

    echo "Verifying the status of remaining OSDs..."
    current_osds=$(ceph osd ls)
    for osd_id in $existing_osds; do
        if [[ ! " ${osd_ids[@]} " =~ " ${osd_id} " ]]; then
            osd_status=$(ceph osd metadata $osd_id | jq -r '.state')
            if [ "$osd_status" != "up" ]; then
                echo "OSD.$osd_id is not up. Attempting to start it."
                systemctl start ceph-osd@${osd_id}
            fi
        fi
    done

    echo "OSD status verification completed."
}

# Function to perform LVM remediation on selected block devices
remediate_lvm() {
    echo "Listing all block devices with their sizes..."
    lsblk -nd -o NAME,SIZE

    read -p "Enter the block devices to remediate (e.g., sda sdb sdc): " -a disks

    echo "You entered the following block devices: ${disks[@]}"
    read -p "Are you sure you want to proceed with LVM remediation on these devices? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborting the operation."
        exit 1
    fi

    for disk in "${disks[@]}"; do
        device="/dev/$disk"
        echo "Processing $device..."

        VG_NAME=$(pvs --noheadings -o vg_name $device | tr -d ' ')
        if [ -n "$VG_NAME" ]; then
            echo "Found VG $VG_NAME on $device"

            LV_PATHS=$(lvs --noheadings -o lv_path $VG_NAME | tr -d ' ')
            for lv_path in $LV_PATHS; do
                echo "Deactivating logical volume: $lv_path"
                run_cmd "lvchange -an $lv_path"
                echo "Removing logical volume: $lv_path"
                run_cmd "lvremove -f $lv_path"
            done

            DM_NAMES=$(dmsetup ls --target crypt | grep "$VG_NAME" | awk '{print $1}')
            for dm_name in $DM_NAMES; do
                echo "Closing encrypted device mapping: $dm_name"
                run_cmd "cryptsetup luksClose $dm_name"
            done

            echo "Checking for open files on VG $VG_NAME"
            lsof_output=$(lsof | grep "$VG_NAME")
            if [ -n "$lsof_output" ]; then
                echo "Found open files:"
                echo "$lsof_output"
                echo "Attempting to kill processes using VG $VG_NAME"
                pids=$(echo "$lsof_output" | awk '{print $2}' | sort | uniq)
                for pid in $pids; do
                    echo "Killing process $pid"
                    kill -9 $pid
                done
            fi

            echo "Deactivating VG $VG_NAME associated with $device"
            run_cmd "vgchange -an $VG_NAME"

            echo "Removing VG $VG_NAME"
            run_cmd "vgremove -f $VG_NAME"

            echo "Removing PV label from $device"
            run_cmd "pvremove --force --force $device"
        else
            echo "No VG found for $device"
        fi

        echo "Zapping $device..."
        run_cmd "ceph-volume lvm zap --destroy $device"
    done

    echo "LVM remediation completed."
}

# Function to create replicated pool
create_replicated_pool() {
    echo "---------------------------------------"
    echo "Create a Replicated Pool"
    echo "---------------------------------------"
    # This utilizes the create_pool function with replicated pool option
    create_pool
}

# Function to create erasure-coded pool
create_ec_pool() {
    echo "---------------------------------------"
    echo "Create an Erasure-Coded Pool"
    echo "---------------------------------------"
    create_pool
}

# Function to configure pool properties
configure_pool_properties() {
    echo "---------------------------------------"
    echo "Configure Pool Properties"
    echo "---------------------------------------"
    # Implementing logic similar to 'set_pool_properties' in the previous script

    list_pools

    while true; do
        read -p "Enter a pool name to configure (or blank to finish): " P_NAME
        if [ -z "$P_NAME" ]; then
            break
        fi
        echo "Options for $P_NAME:"
        echo "1) Set 'bulk' flag (default: false)"
        echo "2) Set pg_autoscale_mode (default: ${DEFAULT_AUTOSCALE_MODE})"
        echo "3) Set compression_algorithm (default: ${DEFAULT_COMPRESSION_ALGO})"
        echo "4) Set compression_mode (default: ${DEFAULT_COMPRESSION_MODE})"
        echo "5) Set size (replication factor) (default: ${DEFAULT_REPLICATION_SIZE})"
        echo "6) Done with this pool"

        while true; do
            read -p "Choose an option (1-6): " PROP_CHOICE
            case $PROP_CHOICE in
                1)
                    read -p "Set bulk to 'true' or 'false' [false]: " BULK_VAL
                    BULK_VAL=${BULK_VAL:-false}
                    run_cmd "ceph osd pool set $P_NAME bulk $BULK_VAL"
                    ;;
                2)
                    read -p "Set pg_autoscale_mode (on/off/warn) [${DEFAULT_AUTOSCALE_MODE}]: " AUTO_VAL
                    AUTO_VAL=${AUTO_VAL:-$DEFAULT_AUTOSCALE_MODE}
                    run_cmd "ceph osd pool set $P_NAME pg_autoscale_mode $AUTO_VAL"
                    ;;
                3)
                    read -p "Set compression_algorithm (none/zstd/lz4/zlib) [${DEFAULT_COMPRESSION_ALGO}]: " CALGO
                    CALGO=${CALGO:-$DEFAULT_COMPRESSION_ALGO}
                    run_cmd "ceph osd pool set $P_NAME compression_algorithm $CALGO"
                    ;;
                4)
                    read -p "Set compression_mode (none/passive/aggressive/force) [${DEFAULT_COMPRESSION_MODE}]: " CMODE
                    CMODE=${CMODE:-$DEFAULT_COMPRESSION_MODE}
                    run_cmd "ceph osd pool set $P_NAME compression_mode $CMODE"
                    ;;
                5)
                    read -p "Set replication size [${DEFAULT_REPLICATION_SIZE}]: " NEW_SIZE
                    NEW_SIZE=${NEW_SIZE:-$DEFAULT_REPLICATION_SIZE}
                    run_cmd "ceph osd pool set $P_NAME size $NEW_SIZE"
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

# Function to create CephFS
create_cephfs() {
    echo "---------------------------------------"
    echo "Create CephFS"
    echo "---------------------------------------"
    # Prompt user for metadata pool and data pool, then create CephFS
    read -p "Enter CephFS name: " FSNAME
    read -p "Enter metadata pool: " METAPOOL
    read -p "Enter data pool: " DATAPOOL
    run_cmd "ceph fs new $FSNAME $METAPOOL $DATAPOOL"
    ceph fs ls
    ceph fs status $FSNAME
}

# Function to manage CephFS pools
manage_cephfs_pools() {
    echo "---------------------------------------"
    echo "Manage CephFS Pools"
    echo "---------------------------------------"
    # Example: add a data pool to an existing filesystem
    read -p "Enter existing CephFS name: " FSNAME
    read -p "Enter new data pool to add: " DATAPOOL
    run_cmd "ceph fs add_data_pool $FSNAME $DATAPOOL"
    ceph fs status $FSNAME
}

# Function to configure encryption
configure_encryption() {
    echo "---------------------------------------"
    echo "Configure Encryption"
    echo "---------------------------------------"
    echo "OSDs are created with dmcrypt option by default in this script."
    echo "Additional encryption configurations can be implemented here if needed."
}

# Function to manage CephX authentication
manage_cephx() {
    echo "---------------------------------------"
    echo "Manage CephX Authentication"
    echo "---------------------------------------"
    echo "Options:"
    echo "1. List existing keys"
    echo "2. Create a new key"
    echo "3. Delete a key"
    echo "4. Modify caps for a key"
    read -p "Enter choice: " CEPHX_CHOICE
    case $CEPHX_CHOICE in
        1)
            echo "Listing all keys..."
            ceph auth list
            ;;
        2)
            read -p "Enter entity name (e.g., client.myuser): " ENTITY
            echo "Enter caps in the format: mon 'allow r' osd 'allow rwx', etc."
            read -p "Enter caps: " CAPS
            run_cmd "ceph auth get-or-create $ENTITY $CAPS"
            ;;
        3)
            read -p "Enter entity name to delete: " ENTITY
            run_cmd "ceph auth del $ENTITY"
            ;;
        4)
            read -p "Enter entity name: " ENTITY
            echo "Enter new caps in format: mon 'allow r', osd 'allow rwx', etc."
            read -p "Enter new caps: " CAPS
            run_cmd "ceph auth caps $ENTITY $CAPS"
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
}

# Function to create CRUSH rules
create_crush_rules() {
    echo "---------------------------------------"
    echo "Create CRUSH Rules"
    echo "---------------------------------------"
    # Example: create a replicated CRUSH rule
    read -p "Enter rule name: " RULENAME
    read -p "Enter device class [default: $DEFAULT_CRUSH_CLASS]: " DEVICECLASS_INPUT
    DEVICECLASS="${DEVICECLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"
    run_cmd "ceph osd crush rule create-replicated $RULENAME default host $DEVICECLASS"
}

# Function to check cluster health
check_cluster_health() {
    echo "---------------------------------------"
    echo "Check Cluster Health"
    echo "---------------------------------------"
    ceph -s
    ceph health detail
}

# Function to show OSD to device mapping
show_osd_device_mapping() {
    echo "---------------------------------------"
    echo "Show OSD to Device Mapping"
    echo "---------------------------------------"
    ceph-volume lvm list
}

# Function to bulk create OSDs
bulk_create_osds() {
    echo "---------------------------------------"
    echo "Bulk Create OSDs"
    echo "---------------------------------------"
    # This can be adapted to run a series of ceph-volume commands as per user input
    read -p "Enter device class for bulk OSD creation [default: $DEFAULT_CRUSH_CLASS]: " BCLASS_INPUT
    BCLASS="${BCLASS_INPUT:-$DEFAULT_CRUSH_CLASS}"
    read -p "Enter space-separated devices (e.g., sda sdb sdc): " BULK_DEVICES

    # Confirm the destructive action
    echo "You are about to zap and create OSDs on the following devices:"
    echo "$BULK_DEVICES"
    confirm_step "This will erase all data on these devices. Do you want to proceed?"

    for d in $BULK_DEVICES; do
        device="/dev/$d"
        run_cmd "ceph-volume lvm zap --destroy $device"
        run_cmd "ceph-volume lvm create --data $device --dmcrypt --crush-device-class $BCLASS"
    done
}

# Main menu loop
while true; do
    echo "---------------------------------------------------------------------------------------------------------------------"
    echo "Ceph Army Knife - Complete Cluster Management - These Commands are Executed Immediately"
    echo "---------------------------------------------------------------------------------------------------------------------"
    echo "Device Management:"
    echo "  1. Bulk Create OSDs (with device class & encryption)"
    echo "  2. Remove OSDs"
    echo "  3. Remediate LVM/Device Issues"
    echo
    echo "Pool Management:"
    echo "  4. Create Metadata Pool (SSD optimized)"
    echo "  5. Create Replicated Pool"
    echo "  6. Create Erasure-Coded Pool"
    echo "  7. Configure Pool Properties (bulk)"
    echo
    echo "Filesystem Management:"
    echo "  8. Create CephFS (with multiple pools)"
    echo "  9. Manage CephFS Data Pools"
    echo
    echo "Security Management:"
    echo "  10. Configure Encryption"
    echo "  11. Manage CephX Authentication"
    echo
    echo "Cluster Management:"
    echo "  12. Create CRUSH Rules"
    echo "  13. Check Cluster Health"
    echo "  14. Show OSD to Device Mapping"
    echo
    echo "  15. Exit"

    read -p "Enter your choice (1-15): " choice

    case $choice in
        1) bulk_create_osds ;;
        2) remove_osds ;;
        3) remediate_lvm ;;
        4) create_metadata_pool ;;
        5) create_replicated_pool ;;
        6) create_ec_pool ;;
        7) configure_pool_properties ;;
        8) create_cephfs ;;
        9) manage_cephfs_pools ;;
        10) configure_encryption ;;
        11) manage_cephx ;;
        12) create_crush_rules ;;
        13) check_cluster_health ;;
        14) show_osd_device_mapping ;;
        15)
            echo "Exiting Ceph Army Knife."
            exit 0
            ;;
        *)
            echo "Invalid choice. Please select a valid option."
            ;;
    esac

    echo
    read -p "Press Enter to continue..."
done
