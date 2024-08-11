#!/bin/bash

# Default settings
DEFAULT_CRUSH_CLASS="SSD4x6"
DEFAULT_POOL_NAME="SSD4x6_pool"
DEFAULT_COMPRESSION_ALGO="zstd"
DEFAULT_COMPRESSION_MODE="passive"
DEFAULT_PG_NUM=128
DEFAULT_AUTOSCALE_MODE="on"
LOGFILE="/var/log/ceph_osd_setup.log"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a ${LOGFILE}
}

# Function to run a command and handle errors
run_cmd() {
    CMD="$1"
    log "Running: $CMD"
    eval $CMD
    if [ $? -ne 0 ]; then
        log "ERROR: Command failed: $CMD"
        exit 1
    fi
}

# Function to confirm a step with user input
confirm_step() {
    MSG="$1"
    echo "$MSG (y/n)"
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        log "User chose not to proceed with: $MSG"
        exit 0
    fi
}

echo "---------------------------------------"
echo "Welcome to the Ceph OSD Setup Script"
echo "---------------------------------------"

log "Script started."

echo "Available block devices:"
lsblk -nd -o NAME,SIZE

read -p "Enter the block devices to use (e.g., sda sdb sdc): " DISK_NAMES
read -p "Enter the name for the pool [default: $DEFAULT_POOL_NAME]: " POOL_NAME_INPUT

echo "---------------------------------------"
echo "**Placement Groups (PGs) Overview:**"
echo "- **What is a PG?**"
echo "  A PG (Placement Group) is a logical container for storing objects."
echo "  PGs allow Ceph to efficiently manage and distribute data across OSDs."
echo "- **Why is PG Number Important?**"
echo "  The number of PGs affects the distribution of data across the cluster."
echo "  Too few PGs can lead to uneven data distribution, while too many PGs"
echo "  can cause excessive overhead and impact performance."
echo "- **Typical Values:**"
echo "  - Small Clusters (e.g., testing or less than 50 OSDs): 128 - 512 PGs"
echo "  - Medium to Large Clusters: 1024 - 4096 PGs"
echo "- **Recommendation:**"
echo "  If unsure, start with a lower number like 128 for smaller setups."
echo "  You can adjust this as your cluster scales."
echo "---------------------------------------"

read -p "Enter the number of PGs [default: $DEFAULT_PG_NUM]: " PG_NUM_INPUT

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

read -p "Create the CRUSH rule cluster-wide? (y/n) [default: y]: " CREATE_CRUSH_RULE

CRUSH_CLASS="${DEFAULT_CRUSH_CLASS}"
POOL_NAME="${POOL_NAME_INPUT:-$DEFAULT_POOL_NAME}"
COMPRESSION_ALGO="${COMPRESSION_ALGO_INPUT:-$DEFAULT_COMPRESSION_ALGO}"
COMPRESSION_MODE="${COMPRESSION_MODE_INPUT:-$DEFAULT_COMPRESSION_MODE}"
PG_NUM="${PG_NUM_INPUT:-$DEFAULT_PG_NUM}"
AUTOSCALE_MODE="${AUTOSCALE_MODE_INPUT:-$DEFAULT_AUTOSCALE_MODE}"

# Display settings before proceeding
echo "---------------------------------------"
echo "You have selected:"
echo "Block Devices: $DISK_NAMES"
echo "CRUSH Device Class: $CRUSH_CLASS"
echo "Pool Name: $POOL_NAME"
echo "Compression Algorithm: $COMPRESSION_ALGO"
echo "Compression Mode: $COMPRESSION_MODE"
echo "Placement Groups (PGs): $PG_NUM"
echo "Autoscale Mode: $AUTOSCALE_MODE"
echo "Create CRUSH rule cluster-wide: ${CREATE_CRUSH_RULE:-y}"
echo "---------------------------------------"

confirm_step "Proceed with these settings?"

# Process each disk
for disk in $DISK_NAMES; do
    device="/dev/$disk"
    log "Processing $device..."

    # Check if LVM data exists on the device
    if pvs --noheadings -o pv_name | grep -q $device; then
        confirm_step "LVM data found on $device. Do you want to wipe existing LVM data?"
        log "Wiping existing LVM data on $device..."
        run_cmd "lvremove -f $(lvdisplay | grep 'LV Path' | grep $device | awk '{print $3}') 2>/dev/null"
        run_cmd "vgremove -f $(pvs $device -o vg_name --noheadings) 2>/dev/null"
        run_cmd "pvremove -y $device 2>/dev/null"
    else
        log "No LVM data found on $device."
    fi

    log "Creating OSD on $device with encryption..."
    run_cmd "ceph-volume lvm create --data $device --dmcrypt --crush-device-class $CRUSH_CLASS"
done

if [[ "${CREATE_CRUSH_RULE:-y}" =~ ^[Yy]$ ]]; then
    log "Creating CRUSH rule for pool..."
    run_cmd "ceph osd crush rule create-replicated ${POOL_NAME}_rule default host $CRUSH_CLASS"
fi

log "Creating pool with name $POOL_NAME and PG number $PG_NUM..."
run_cmd "ceph osd pool create $POOL_NAME $PG_NUM $PG_NUM replicated ${POOL_NAME}_rule"

log "Setting compression algorithm to $COMPRESSION_ALGO..."
run_cmd "ceph osd pool set $POOL_NAME compression_algorithm $COMPRESSION_ALGO"

log "Setting compression mode to $COMPRESSION_MODE..."
run_cmd "ceph osd pool set $POOL_NAME compression_mode $COMPRESSION_MODE"

log "Setting autoscale mode to $AUTOSCALE_MODE..."
run_cmd "ceph osd pool set $POOL_NAME pg_autoscale_mode $AUTOSCALE_MODE"

log "Ceph OSD setup completed successfully."
