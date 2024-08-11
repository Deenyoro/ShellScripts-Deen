#!/bin/bash

# Function to remove OSDs
remove_osds() {
    echo "Listing all known OSDs and their CRUSH class..."
    ceph osd tree | awk '/osd\.[0-9]+/ {print $1, $2, $3}'

    read -p "Enter the OSD IDs you want to remove, separated by spaces: " -a osd_ids

    echo "You entered the following OSD IDs: ${osd_ids[@]}"
    read -p "Are you sure you want to proceed with removing these OSDs? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        echo "Aborting the operation."
        exit 1
    fi

    echo "Stopping ceph-osd services..."
    systemctl stop ceph-osd.target

    for osd_id in "${osd_ids[@]}"; do
        echo "Processing OSD ID: $osd_id"
        
        ceph osd out osd.${osd_id}
        sleep 2
        
        ceph osd crush remove osd.${osd_id}
        sleep 2
        
        ceph auth del osd.${osd_id}
        sleep 2
        
        ceph osd down osd.${osd_id}
        sleep 2
        
        ceph osd rm osd.${osd_id}
        sleep 2
        
        echo "OSD ID: $osd_id has been removed."
    done

    echo "All specified OSDs have been processed."
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

    echo "Deactivating volume groups..."
    for disk in "${disks[@]}"; do
        vg=$(pvs --noheadings -o vg_name /dev/$disk | tr -d ' ')
        if [ -n "$vg" ]; then
            echo "Deactivating VG: $vg"

            # Unmount the logical volumes associated with the VG
            lv_paths=$(lvdisplay | grep "LV Path" | grep $vg | awk '{print $3}')
            for lv_path in $lv_paths; do
                echo "Attempting to unmount $lv_path"
                umount $lv_path || echo "$lv_path was not mounted."
            done

            # Kill any processes using the LV
            echo "Checking for open files on $vg"
            lsof_output=$(lsof | grep "$vg")
            if [ -n "$lsof_output" ]; then
                echo "Killing processes using $vg"
                echo "$lsof_output" | awk '{print $2}' | xargs -r kill -9
            fi

            # Remove device mappings
            dm_name=$(dmsetup info -c | grep $vg | awk '{print $1}')
            if [ -n "$dm_name" ]; then
                echo "Removing device mapping $dm_name"
                dmsetup remove $dm_name || { echo "Failed to remove device mapping $dm_name"; exit 1; }
            fi

            # Deactivate the logical volumes and the VG
            lvchange -an $vg || { echo "Failed to deactivate logical volumes in volume group $vg"; exit 1; }
            vgchange -an $vg || { echo "Failed to deactivate volume group $vg"; exit 1; }
        else
            echo "No VG found for $disk"
        fi
    done

    echo "Removing LVM structures..."
    for disk in "${disks[@]}"; do
      lv=$(lvdisplay | grep "LV Path" | grep $disk | awk '{print $3}')
      if [ -n "$lv" ]; then
        echo "Removing LV: $lv"
        lvremove -f $lv 2>/dev/null || { echo "Failed to remove logical volume $lv"; exit 1; }
      else
        echo "No LV found for $disk"
      fi

      vg=$(pvs --noheadings -o vg_name /dev/$disk | tr -d ' ')
      if [ -n "$vg" ]; then
        echo "Removing VG: $vg"
        vgremove -f $vg 2>/dev/null || { echo "Failed to remove volume group $vg"; exit 1; }
      fi

      echo "Wiping PV label on /dev/$disk"
      pvremove --force --force /dev/$disk || { echo "Failed to wipe PV label on /dev/$disk"; exit 1; }
    done

    echo "LVM cleanup completed."
}

# Main script logic
echo "What would you like to do?"
echo "1. Remove OSDs"
echo "2. Remediate LVM on selected block devices"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        remove_osds
        ;;
    2)
        remediate_lvm
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "Script execution completed successfully."
