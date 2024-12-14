#!/bin/bash

################################################################################
# Script Name: opnsense_mount_config_usb2VM.sh
# Description: Automates the creation of a FAT32-formatted USB image containing
#              the OPNsense configuration XML file and attaches it to a specified
#              Proxmox VM for automated configuration import during installation.
#              The script supports both command-line options and an interactive menu.
# Requirements:
#   - Proxmox VE environment with qm CLI tool installed.
#   - Existing OPNsense VM or knowledge of VM ID to attach the USB image.
#   - Config.xml file prepared and accessible on the Proxmox node.
# Usage:
#   # Using command-line options
#   sudo ./create_opnsense_config_usb.sh \
#       -c /path/to/config.xml \
#       -s 10M \
#       -i 100 \
#       -l ConfigUSB \
#       -t local
#
#   # Running interactively (no options)
#   sudo ./create_opnsense_config_usb.sh
#
# Options:
#   -c PATH      Path to the config.xml file.
#   -s SIZE      Size of the FAT32 image (e.g., 10M for 10 Megabytes).
#   -i VM_ID     Proxmox VM ID to which the USB image will be attached.
#   -l LABEL     Volume label for the FAT32 USB image.
#   -t STORAGE   Proxmox storage identifier (e.g., local, local-lvm).
#   -h           Display this help message.
################################################################################

# Exit immediately if a command exits with a non-zero status.
set -e

################################################################################
# Function to display usage information.
################################################################################
usage() {
    echo "Usage: sudo $0 -c /path/to/config.xml -s SIZE -i VM_ID -l LABEL -t STORAGE"
    echo ""
    echo "Options:"
    echo "  -c PATH      Path to the config.xml file."
    echo "  -s SIZE      Size of the FAT32 image (e.g., 10M for 10 Megabytes)."
    echo "  -i VM_ID     Proxmox VM ID to which the USB image will be attached."
    echo "  -l LABEL     Volume label for the FAT32 USB image."
    echo "  -t STORAGE   Proxmox storage identifier (e.g., local, local-lvm)."
    echo "  -h           Display this help message."
    exit 1
}

################################################################################
# Function to prompt the user for input in interactive mode.
################################################################################
interactive_mode() {
    echo "========================================"
    echo "OPNsense Configuration USB Creator"
    echo "========================================"
    
    # Prompt for the path to the config.xml file.
    while true; do
        read -rp "Enter the full path to your config.xml file: " CONFIG_XML_PATH
        if [[ -f "$CONFIG_XML_PATH" ]]; then
            echo "Config.xml found at '$CONFIG_XML_PATH'."
            break
        else
            echo "Error: config.xml file not found at '$CONFIG_XML_PATH'. Please try again."
        fi
    done
    
    # Prompt for the size of the FAT32 image.
    while true; do
        read -rp "Enter the size of the FAT32 image (e.g., 10M for 10 Megabytes): " IMAGE_SIZE
        IMAGE_SIZE_NUM=$(echo "$IMAGE_SIZE" | sed -E 's/^([0-9]+)M$/\1/')
        if [[ -n "$IMAGE_SIZE_NUM" ]]; then
            echo "Image size set to $IMAGE_SIZE."
            break
        else
            echo "Error: SIZE should be in the format of <number>M (e.g., 10M). Please try again."
        fi
    done
    
    # Prompt for the Proxmox VM ID.
    while true; do
        read -rp "Enter the Proxmox VM ID to attach the USB image: " VM_ID
        if qm list | awk '{print $1}' | grep -qw "$VM_ID"; then
            echo "VM ID $VM_ID found."
            break
        else
            echo "Error: VM ID $VM_ID does not exist. Please try again."
        fi
    done
    
    # Prompt for the volume label of the USB image.
    while true; do
        read -rp "Enter the volume label for the FAT32 USB image: " USB_LABEL
        if [[ -n "$USB_LABEL" ]]; then
            echo "USB volume label set to '$USB_LABEL'."
            break
        else
            echo "Error: Volume label cannot be empty. Please try again."
        fi
    done
    
    # Prompt for the Proxmox storage identifier.
    while true; do
        read -rp "Enter the Proxmox storage identifier (e.g., local, local-lvm): " STORAGE
        if pvesm status | awk '{print $1}' | grep -qw "$STORAGE"; then
            echo "Storage identifier '$STORAGE' found."
            break
        else
            echo "Error: Storage identifier '$STORAGE' does not exist. Please try again."
        fi
    done
}

################################################################################
# Function to create and attach the OPNsense configuration USB image.
################################################################################
create_and_attach_usb() {
    # Define temporary variables.
    IMAGE_FILE="/tmp/opnsense_config.img"  # Temporary image file path.
    
    ################################################################################
    # Step 1: Create an empty image file of the specified size.
    ################################################################################
    echo "Step 1: Creating a $IMAGE_SIZE FAT32 image at $IMAGE_FILE..."
    # Create an empty image file filled with zeros.
    dd if=/dev/zero of="$IMAGE_FILE" bs=1M count="$IMAGE_SIZE_NUM" status=progress
    
    ################################################################################
    # Step 2: Format the image as FAT32 with the specified volume label.
    ################################################################################
    echo "Step 2: Formatting the image as FAT32 with label '$USB_LABEL'..."
    mkfs.vfat -F 32 -n "$USB_LABEL" "$IMAGE_FILE"
    
    ################################################################################
    # Step 3: Mount the image to a temporary directory.
    ################################################################################
    echo "Step 3: Mounting the image..."
    # Create a temporary mount point directory.
    MOUNT_POINT=$(mktemp -d)
    echo "Mount point created at $MOUNT_POINT."
    # Mount the image file to the mount point using loop device.
    mount -o loop "$IMAGE_FILE" "$MOUNT_POINT"
    
    ################################################################################
    # Step 4: Create the necessary directory structure and copy config.xml.
    ################################################################################
    echo "Step 4: Creating /conf directory and copying config.xml..."
    # Create the /conf directory inside the mounted image.
    mkdir -p "$MOUNT_POINT/conf"
    # Copy the config.xml file to /conf/config.xml within the image.
    cp "$CONFIG_XML_PATH" "$MOUNT_POINT/conf/config.xml"
    
    ################################################################################
    # Step 5: Unmount the image and remove the temporary mount point.
    ################################################################################
    echo "Step 5: Unmounting the image and cleaning up..."
    # Unmount the image from the mount point.
    umount "$MOUNT_POINT"
    # Remove the temporary mount point directory.
    rmdir "$MOUNT_POINT"
    echo "Image unmounted and mount point removed."
    
    ################################################################################
    # Step 6: (Optional) Verify the image is in raw format.
    # Since the image is already in raw format, this step is skipped.
    ################################################################################
    echo "Step 6: Skipping format conversion as the image is already in raw format."
    
    ################################################################################
    # Step 7: Upload the image to Proxmox storage.
    ################################################################################
    echo "Step 7: Uploading the image to Proxmox storage at $DEST_PATH..."
    # Define the destination path in Proxmox storage for the VM.
    DEST_PATH="/var/lib/vz/images/$VM_ID/opnsense_config.img"
    # Create the destination directory if it doesn't exist.
    mkdir -p "$(dirname "$DEST_PATH")"
    # Copy the image file to the Proxmox storage.
    cp "$IMAGE_FILE" "$DEST_PATH"
    echo "Image copied to $DEST_PATH."
    
    ################################################################################
    # Step 8: Attach the image to the specified VM as a VirtIO disk.
    ################################################################################
    echo "Step 8: Attaching the image to VM ID $VM_ID as a VirtIO disk..."
    # List existing VirtIO devices for the specified VM.
    EXISTING_VIRTIO=$(qm config "$VM_ID" | grep "^virtio" | awk -F: '{print $1}' | sort)
    
    # Initialize variable to hold the next available VirtIO slot.
    VIRTIO_SLOT=""
    
    # Loop through possible VirtIO slots from virtio0 to virtio9.
    for i in {0..9}; do
        SLOT="virtio$i"
        # Check if the slot is already in use.
        if ! echo "$EXISTING_VIRTIO" | grep -q "^$SLOT"; then
            VIRTIO_SLOT="$SLOT"
            break
        fi
    done
    
    # If no available VirtIO slot is found, exit with an error.
    if [[ -z "$VIRTIO_SLOT" ]]; then
        echo "Error: No available VirtIO slots found for VM ID $VM_ID." 1>&2
        exit 1
    fi
    
    # Attach the image to the VM using the available VirtIO slot.
    qm set "$VM_ID" --"$VIRTIO_SLOT" "$STORAGE":/images/"$VM_ID"/opnsense_config.img,format=raw
    echo "Image attached to VM ID $VM_ID as $VIRTIO_SLOT."
    
    ################################################################################
    # Step 9: (Optional) Clean up the temporary image file.
    # Uncomment the following lines if you wish to remove the temporary image after copying.
    ################################################################################
    # echo "Step 9: Cleaning up temporary files..."
    # rm -f "$IMAGE_FILE"
    # echo "Temporary files removed."
    
    ################################################################################
    # Final Message
    ################################################################################
    echo "========================================"
    echo "OPNsense configuration USB image is ready and attached to VM ID $VM_ID as $VIRTIO_SLOT."
    echo "Proceed to boot the OPNsense VM and use the Importer to load the configuration from the attached VirtIO disk ($VIRTIO_SLOT)."
    echo "========================================"
}

################################################################################
# Main Script Execution
################################################################################

# Check if the script is run with command-line options.
if [[ $# -gt 0 ]]; then
    # Parse command-line options as usual.
    # Initialize variables to store user inputs.
    CONFIG_XML_PATH=""
    IMAGE_SIZE=""
    VM_ID=""
    USB_LABEL=""
    STORAGE=""
    
    # Parse command-line options using getopts.
    while getopts ":c:s:i:l:t:h" opt; do
        case ${opt} in
            c )
                CONFIG_XML_PATH=$OPTARG
                ;;
            s )
                IMAGE_SIZE=$OPTARG
                ;;
            i )
                VM_ID=$OPTARG
                ;;
            l )
                USB_LABEL=$OPTARG
                ;;
            t )
                STORAGE=$OPTARG
                ;;
            h )
                usage
                ;;
            \? )
                echo "Invalid Option: -$OPTARG" 1>&2
                usage
                ;;
            : )
                echo "Invalid Option: -$OPTARG requires an argument" 1>&2
                usage
                ;;
        esac
    done
    shift $((OPTIND -1))
    
    # Validate that all required arguments are provided.
    if [[ -z "$CONFIG_XML_PATH" || -z "$IMAGE_SIZE" || -z "$VM_ID" || -z "$USB_LABEL" || -z "$STORAGE" ]]; then
        echo "Error: All options -c, -s, -i, -l, and -t are required." 1>&2
        usage
    fi
    
    # Check if the config.xml file exists at the specified path.
    if [[ ! -f "$CONFIG_XML_PATH" ]]; then
        echo "Error: config.xml file not found at '$CONFIG_XML_PATH'." 1>&2
        exit 1
    fi
    
    # Call the function to create and attach the USB image.
    create_and_attach_usb
else
    # If no command-line options are provided, enter interactive mode.
    interactive_mode
    
    # After collecting inputs interactively, call the function to create and attach the USB image.
    create_and_attach_usb
fi

# Exit the script successfully.
exit 0
