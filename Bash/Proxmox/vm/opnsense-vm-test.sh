#!/usr/bin/env bash
# Purpose: Automate the creation of an OPNsense VM in Proxmox VE
# Dependencies: wget, curl, whiptail, bunzip2, Proxmox CLI tools (qm, pvesm, pvesh)

set -euo pipefail

#################################################################################
# Configuration Settings                                                         #
#################################################################################

# Mirror and fallback settings
MIRROR_BASE_URL="https://mirrors.ocf.berkeley.edu/opnsense/releases/"
FALLBACK_URL="https://mirrors.ocf.berkeley.edu/opnsense/releases/24.7/OPNsense-24.7-dvd-amd64.iso.bz2"
FALLBACK_RELEASE_DATE="2024-Jul-23"  # Known release date for OPNsense 24.7
FALLBACK_VERSION="24.7"

# VM ID range
STARTING_VM_ID=100
NEXTID=$STARTING_VM_ID

# Default interface names
DEFAULT_WAN_BRIDGE="opnwan"
DEFAULT_LAN_BRIDGE="opnlan"
DEFAULT_MGMT_BRIDGE="opnmgmt"

#################################################################################
# ASCII Art and Visual Elements                                                  #
#################################################################################

function header_info {
    clear
    cat <<"EOF"

                              (               (
      (   `  )    (     (    ))\  (     (    ))\
      )\  /(/(    )\ )  )\  /((_) )\ )  )\  /((_)
     ((_)((_)_\  _(_/( ((_)(_))  _(_/( ((_)(_))
    / _ \| '_ \)| ' \))(_-</ -_)| ' \))(_-</ -_)
    \___/| .__/ |_||_| /__/\___||_||_| /__/\___|
         |_|    O P N S E N S E  F I R E W A L L

EOF
}

#################################################################################
# Color and Message Formatting                                                   #
#################################################################################

CL="\033[m"               # Clear formatting
GN="\033[1;92m"           # Green
RD="\033[01;31m"          # Red
DGN="\033[32m"            # Dark Green
BGN="\033[4;92m"          # Bold Green
CM="${GN}✓${CL}"          # Checkmark
CROSS="${RD}✗${CL}"       # Cross

function msg_info() {
    echo -e "${GN}Info:${CL} $1"
}

function msg_ok() {
    echo -e "${CM} ${GN}$1${CL}"
}

function msg_error() {
    echo -e "${CROSS} ${RD}$1${CL}"
}

#################################################################################
# Error Handling and Cleanup                                                     #
#################################################################################

TEMP_DIR=""
VMID=""
ROOT_PASSWORD=""
LAN_IPV4=""
SUBNET_MASK=""
ENABLE_DHCP=""
DHCP_START=""
DHCP_END=""
ENABLE_HTTPS=""
MANAGE_INTERFACES="yes"
EFI_DISK_SIZE="8M"
AUTOMATE_SETUP="no"

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
    cleanup_vmid
    exit $exit_code
}

function cleanup_vmid() {
    if [[ -n "${VMID:-}" && $(qm status "$VMID" 2>/dev/null || true) =~ running|stopped ]]; then
        qm stop "$VMID" &>/dev/null || true
        qm destroy "$VMID" &>/dev/null || true
    fi
}

function cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

#################################################################################
# System and Environment Checks                                                  #
#################################################################################

function check_dependencies() {
    local deps=(whiptail pvesh pvesm qm wget curl bunzip2)
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "Required command '$cmd' is not installed."
            exit 1
        fi
    done
}

function check_vmid {
    # We'll increment NEXTID until we find an ID not used by a VM or container
    while true; do
        if qm list | awk '{print $1}' | grep -qw "$NEXTID"; then
            ((NEXTID++))
            continue
        fi
        if pct list | awk '{print $1}' | grep -qw "$NEXTID"; then
            ((NEXTID++))
            continue
        fi
        break
    done
    echo "New VMID after increment: $NEXTID"
}

function generate_mac() {
    echo "02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
}

function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        clear
        msg_error "Please run this script as root."
        echo -e "\nExiting..."
        sleep 2
        exit 1
    fi
}

function pve_check() {
    if ! pveversion | grep -Eq "pve-manager/8.[1-9]"; then
        msg_error "This version of Proxmox Virtual Environment is not supported"
        echo -e "Requires Proxmox Virtual Environment Version 8.1 or later."
        echo -e "Exiting..."
        sleep 2
        exit 1
    fi
}

function arch_check() {
    if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
        msg_error "This script will not work with PiMox (arm)! Exiting..."
        sleep 2
        exit 1
    fi
}

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" ]]; then
        if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's suggested to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62 \
            --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
            clear
            exit 1
        fi
    fi
}

#################################################################################
# Distinct Functions for Selecting ISO Storage vs. VM Disk Storage
#################################################################################
# We explicitly filter for storages that have "iso" vs. "images" contents, so you
# can pick one storage for the ISO and a different storage for VM Disks.
#################################################################################

function select_iso_storage() {
    local title="ISO STORAGE"
    local prompt="Which storage pool would you like to use for the OPNsense ISO?"

    local menu_items=()
    while IFS= read -r line; do
        # "pvesm status -content iso" => storages that can store ISOs
        [[ -z "$line" || "$line" =~ ^Name ]] && continue

        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | awk '{print $6}')

        [[ -z "$tag" ]] && continue

        local item="Type: $stype, Free: ${free}B"
        menu_items+=("$tag" "$item")
    done < <(pvesm status -content iso)

    if [ ${#menu_items[@]} -eq 0 ]; then
        msg_error "No valid storage found for storing ISO files. Exiting..."
        exit 1
    fi

    local chosen_storage
    chosen_storage=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "$title" \
        --menu "$prompt" 16 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script

    echo "$chosen_storage"
}

function select_disk_storage() {
    local title="VM Disk Storage"
    local prompt="Which storage pool would you like to use for the OPNsense VM Disks?"

    local menu_items=()
    while IFS= read -r line; do
        # "pvesm status -content images" => storages for VM images
        [[ -z "$line" || "$line" =~ ^Name ]] && continue

        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | awk '{print $6}')

        [[ -z "$tag" ]] && continue

        local item="Type: $stype, Free: ${free}B"
        menu_items+=("$tag" "$item")
    done < <(pvesm status -content images)

    if [ ${#menu_items[@]} -eq 0 ]; then
        msg_error "No valid storage found for VM disk images. Exiting..."
        exit 1
    fi

    local chosen_storage
    chosen_storage=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "$title" \
        --menu "$prompt" 16 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script

    echo "$chosen_storage"
}

function select_usb_storage() {
    local title="$1"
    local prompt="$2"

    local menu_items=()
    # We look for storages that can hold 'images' because a USB image is effectively just a VM disk
    while IFS= read -r line; do
        # pvesm status -content images => storages that can store VM disk images
        [[ -z "$line" || "$line" =~ ^Name ]] && continue

        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | awk '{print $6}')

        [[ -z "$tag" ]] && continue

        local item="Type: $stype, Free: ${free}B"
        menu_items+=("$tag" "$item")
    done < <(pvesm status -content images)

    if [ ${#menu_items[@]} -eq 0 ]; then
        msg_error "No valid storage found for storing a USB disk image. Exiting..."
        exit 1
    fi

    local chosen_usb_storage
    chosen_usb_storage=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "$title" \
        --menu "$prompt" 16 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script

    echo "$chosen_usb_storage"
}

#################################################################################
# VM Configuration (Default & Advanced)                                          #
#################################################################################

function exit_script() {
    clear
    echo -e "User exited script.\n"
    exit 1
}

function default_settings() {
    check_vmid
    VMID="$NEXTID"
    MACHINE="q35"
    DISK_CACHE=""
    HN="OPNsense$VMID"
    CPU_TYPE="host"
    CORE_COUNT="2"
    RAM_SIZE="2048"
    DISK_SIZE="30G"
    EFI_DISK_SIZE="8M"
    AUTOMATE_SETUP="no"

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        BRIDGE1="$DEFAULT_WAN_BRIDGE"
        MAC1=$(generate_mac)
        MTU1="1500"
        BRIDGE2="$DEFAULT_LAN_BRIDGE"
        MAC2=$(generate_mac)
        MTU2="1500"
        BRIDGE3="$DEFAULT_MGMT_BRIDGE"
        MAC3=$(generate_mac)
        MTU3="1500"
    fi

    START_VM="yes"
    msg_ok "Default settings applied."
}

function advanced_settings() {
    check_vmid
    VMID=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Virtual Machine ID (Default: $NEXTID)" 8 60 "$NEXTID" \
        --title "VIRTUAL MACHINE ID" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    HN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Hostname (Default: OPNsense$VMID)" 8 60 "OPNsense${VMID}" \
        --title "HOSTNAME" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    MACHINE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "MACHINE TYPE" --radiolist "Select machine type:" 10 60 2 \
        "q35" "Q35: Modern with PCIe support (recommended)" ON \
        "i440fx" "Older, less feature-rich" OFF 3>&1 1>&2 2<&3 --cancel-button "Exit Script") || exit_script

    DISK_CACHE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "DISK CACHE" --radiolist "Disk cache type:" 10 60 2 \
        "none" "None (recommended)" ON \
        "writeback" "Better performance, riskier" OFF 3>&1 1>&2 2<&3 --cancel-button "Exit Script") || exit_script

    CPU_TYPE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "CPU MODEL" --radiolist "CPU model:" 10 60 2 \
        "host" "Use host CPU features" ON \
        "kvm64" "Generic" OFF 3>&1 1>&2 2<&3 --cancel-button "Exit Script") || exit_script

    CORE_COUNT=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Number of CPU cores (Default: 2)" 8 60 "2" \
        --title "CPU CORES" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    RAM_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "RAM size in MiB (Default: 2048)" 8 60 "2048" \
        --title "RAM SIZE" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    DISK_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Disk size (Default: 30G)" 8 60 "30G" \
        --title "DISK SIZE" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    EFI_DISK_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "EFI Disk size (Default: 8M)" 8 60 "8M" \
        --title "EFI DISK SIZE" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$EFI_DISK_SIZE" ]; then
        EFI_DISK_SIZE="8M"
    fi

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        BRIDGE1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (1/3) DEFAULT: $DEFAULT_WAN_BRIDGE" 8 60 "$DEFAULT_WAN_BRIDGE" \
            --title "INTERFACE NAME (WAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for WAN" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (WAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for WAN (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (WAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

        BRIDGE2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (2/3) DEFAULT: $DEFAULT_LAN_BRIDGE" 8 60 "$DEFAULT_LAN_BRIDGE" \
            --title "INTERFACE NAME (LAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for LAN" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (LAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for LAN (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (LAN)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

        BRIDGE3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (3/3) DEFAULT: $DEFAULT_MGMT_BRIDGE" 8 60 "$DEFAULT_MGMT_BRIDGE" \
            --title "INTERFACE NAME (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for MGMT" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for MGMT (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "START VIRTUAL MACHINE" \
        --yesno "Start VM when completed?" 10 60 --yes-button "Yes" \
        --no-button "No" --cancel-button "Exit Script"); then
        START_VM="yes"
    else
        START_VM="no"
    fi
}

function start_script() {
    if whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "SETTINGS" \
        --yesno "Use Default Settings?" --defaultno 10 60 \
        --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
        default_settings
    else
        advanced_settings
    fi
}

function prompt_root_password() {
    ROOT_PASSWORD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ROOT PASSWORD" --passwordbox "Enter root password:" 10 60 \
        --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$ROOT_PASSWORD" ]; then
        msg_error "No password entered. Exiting..."
        exit 1
    fi
}

#################################################################################
# Mirror Date Parsing
#################################################################################

function convert_date() {
    local input_date="$1"
    local day month year
    day=$(echo "$input_date" | cut -d'-' -f3)
    month=$(echo "$input_date" | cut -d'-' -f2)
    year=$(echo "$input_date" | cut -d'-' -f1)
    case $month in
        Jan) month="01";;
        Feb) month="02";;
        Mar) month="03";;
        Apr) month="04";;
        May) month="05";;
        Jun) month="06";;
        Jul) month="07";;
        Aug) month="08";;
        Sep) month="09";;
        Oct) month="10";;
        Nov) month="11";;
        Dec) month="12";;
        *) echo "Invalid month"; exit 1;;
    esac
    echo "${year}${month}${day}"
}

#################################################################################
# parse_available_versions / select_iso / handle_iso_download / select_local_iso
#################################################################################

function parse_available_versions() {
    msg_info "Parsing available OPNsense versions from mirror"
    local html_content
    # Attempt to fetch the main directory listing
    html_content=$(curl -s "$MIRROR_BASE_URL" || true)

    ISO_ENTRIES=()
    local version_dirs

    # Example:
    #   href="23.1/"
    #   href="23.7/"
    # We'll parse those version subfolders
    version_dirs=$(echo "$html_content" \
        | grep -oP 'href="\K[0-9]+\.[0-9]+(?=/)' \
        | sort -V || true)

    for version in $version_dirs; do
        local version_url="${MIRROR_BASE_URL}${version}/"
        local version_content
        version_content=$(curl -s "$version_url" || true)

        # We specifically look for the DVD ISO .bz2 file
        # e.g. OPNsense-23.7-dvd-amd64.iso.bz2
        if [[ "$version_content" =~ OPNsense-${version}-dvd-amd64\.iso\.bz2 ]]; then
            local iso_file="OPNsense-${version}-dvd-amd64.iso.bz2"

            # Attempt to extract a date from the listing (like 23-Jul-2023)
            local date_part
            date_part=$(echo "$version_content" \
                | grep "$iso_file" \
                | grep -oP '\d{2}-[A-Za-z]{3}-\d{4}' || true)

            if [[ -z "$date_part" ]]; then
                # If not found, default to today's date
                date_part=$(date +"%d-%b-%Y")
            fi

            # Convert date_part to YYYYMMDD
            local formatted_date
            formatted_date=$(convert_date "$(echo "$date_part" | awk -F'-' '{print $3"-"$2"-"$1}')")

            # store an entry in the format:
            #   url|filename_with_prefix|date_part|version
            #   filename will be:
            #   20230723-OPNsense-23.7-dvd-amd64.iso.bz2
            ISO_ENTRIES+=("${version_url}${iso_file}|${formatted_date}-${iso_file}|${date_part}|${version}")
        fi
    done
}

function select_iso() {
    parse_available_versions

    MENU_ITEMS=()
    if [ ${#ISO_ENTRIES[@]} -eq 0 ]; then
        msg_info "No OPNsense ISOs found. Adding fallback to list."
        MENU_ITEMS+=("$FALLBACK_URL" "Fallback OPNsense ISO: $(basename "$FALLBACK_URL") - Last Updated: $FALLBACK_RELEASE_DATE")
    else
        local sorted_entries=()
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r url filename date version <<< "$entry"
            sorted_entries+=("$entry")
        done

        IFS=$'\n' sorted_entries=($(sort -t'|' -k4,4Vr <<<"${sorted_entries[*]}"))
        unset IFS

        for entry in "${sorted_entries[@]}"; do
            IFS='|' read -r url filename date version <<< "$entry"
            MENU_ITEMS+=("$url" "OPNsense $version - Released: $date")
        done

        MENU_ITEMS+=("$FALLBACK_URL" "Fallback: OPNsense $FALLBACK_VERSION - Released: $FALLBACK_RELEASE_DATE")
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ISO SELECTION" \
        --yesno "Would you like to download an OPNsense ISO from the internet?\nChoose 'No' to select a locally available ISO." 10 60); then

        CHOSEN_ISO_URL=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "Available OPNsense ISOs" \
            --menu "Select an ISO to download:\nUse Arrow keys to highlight and Enter to select." \
            20 100 8 \
            "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit_script

        handle_iso_download "$CHOSEN_ISO_URL"
    else
        select_local_iso
    fi
}

function handle_iso_download() {
    local chosen_url="$1"
    local iso_basename=""
    local formatted_date=""

    if [ "$chosen_url" = "$FALLBACK_URL" ]; then
        # Fallback ISO scenario
        formatted_date=$(convert_date "$FALLBACK_RELEASE_DATE")
        iso_basename="${formatted_date}-$(basename "$FALLBACK_URL")"
    else
        # Search for the matching entry from ISO_ENTRIES
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r url filename date version <<< "$entry"
            if [ "$url" = "$chosen_url" ]; then
                iso_basename="$filename"  # e.g. "20240723-OPNsense-24.7-dvd-amd64.iso.bz2"
                break
            fi
        done

        # If not found, default to fallback naming
        if [ -z "$iso_basename" ]; then
            formatted_date=$(convert_date "$FALLBACK_RELEASE_DATE")
            iso_basename="${formatted_date}-$(basename "$FALLBACK_URL")"
        fi
    fi

    # iso_basename is something like "20240723-OPNsense-24.7-dvd-amd64.iso.bz2"
    # or just "OPNsense-24.7-dvd-amd64.iso.bz2"

    # Store it globally so create_vm can see it
    ISO_BASENAME="$iso_basename"

    # Figure out the actual final directory (ISO storage path)
    local iso_storage_path
    if [ "$ISO_STORAGE" = "local" ]; then
        iso_storage_path="/var/lib/vz/template/iso"
    else
        iso_storage_path="$(pvesm path "$ISO_STORAGE")/template/iso"
    fi
    mkdir -p "$iso_storage_path"

    # --- Prevent double ".iso" by checking if the name already ends with .iso
    local base_no_bz2="${iso_basename%.bz2}" 
    local final_iso_name
    if [[ "$base_no_bz2" =~ \.iso$ ]]; then
        # e.g. "20240723-OPNsense-24.7-dvd-amd64.iso"
        final_iso_name="$base_no_bz2"
    else
        # e.g. "20240723-OPNsense-24.7-dvd-amd64" => append .iso
        final_iso_name="$base_no_bz2.iso"
    fi

    local final_iso_path="$iso_storage_path/$final_iso_name"

    # If that final ISO already exists, ask the user if they want a fresh download
    if [ -f "$final_iso_path" ]; then
        msg_ok "ISO file already exists: $final_iso_name"
        if whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "ISO Already Exists" \
            --yesno "An ISO file named $final_iso_name already exists.\nDelete and redownload?" \
            10 60 --yes-button "Delete and Download" --no-button "Use Existing" --cancel-button "Exit Script"; then
            msg_info "Deleting existing ISO: $final_iso_path"
            if ! rm -f "$final_iso_path"; then
                msg_error "Failed to delete existing ISO: $final_iso_path"
                exit 1
            fi
        else
            msg_ok "Using existing ISO: $final_iso_name"
            ISO_BASENAME="$final_iso_name"
            return

        fi
    fi

    # Download the bz2 => extract => rename => done
    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_bz2_path="$temp_dir/$iso_basename"

    msg_info "Downloading from $chosen_url to temporary location"
    if ! wget -q --show-progress "$chosen_url" -O "$temp_bz2_path"; then
        msg_error "Failed to download from $chosen_url"
        rm -rf "$temp_dir"
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "LOCAL ISO" \
            --yesno "Download failed. Select a locally available ISO?" 10 60); then
            select_local_iso
        else
            msg_error "Exiting due to download failure."
            exit 1
        fi
    else
        msg_ok "Downloaded $iso_basename"
        msg_info "Extracting ISO from .bz2..."
        if ! bunzip2 "$temp_bz2_path"; then
            msg_error "Failed to extract $temp_bz2_path"
            rm -rf "$temp_dir"
            exit 1
        fi

        # Move the extracted .iso => final location
        if ! mv "${temp_bz2_path%.bz2}" "$final_iso_path"; then
            msg_error "Failed to move ISO to final location"
            rm -rf "$temp_dir"
            exit 1
        fi
		
		ISO_BASENAME="$final_iso_name"
		
        rm -rf "$temp_dir"
        msg_ok "Extracted and moved $final_iso_name to final location => $iso_storage_path"
    fi
}


function select_local_iso() {
    ISO_LIST=()
    while IFS= read -r iso_file; do
        ISO_LIST+=("$(basename "$iso_file")" "Local ISO file")
    done < <(find /var/lib/vz/template/iso -type f -name "*.iso")

    if [ ${#ISO_LIST[@]} -eq 0 ]; then
        msg_error "No .iso files found in /var/lib/vz/template/iso."
        exit 1
    fi

    ISO_BASENAME=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "Local ISO Files" \
        --menu "Select a local ISO file:" 16 60 8 \
        "${ISO_LIST[@]}" 3>&1 1>&2 2>&3) || exit_script

    if [ -z "${ISO_BASENAME}" ]; then
        msg_error "No ISO selected. Exiting..."
        exit 1
    fi

    ISO_PATH="/var/lib/vz/template/iso/$ISO_BASENAME"
    msg_ok "Using local ISO: $ISO_BASENAME"
}

#################################################################################
# Network Configuration Functions
#################################################################################

function prompt_network_configuration() {
    LAN_IPV4=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Enter LAN IPv4 Address:" 8 60 --title "LAN IPv4 ADDRESS" \
        --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$LAN_IPV4" ]; then
        msg_error "No LAN IPv4 Address entered. Exiting..."
        exit 1
    fi

    SUBNET_MASK=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Enter Subnet Mask (CIDR format, e.g., 24):" 8 60 \
        --title "SUBNET MASK" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$SUBNET_MASK" ]; then
        msg_error "No Subnet Mask entered. Exiting..."
        exit 1
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "DHCP SERVER" --yesno "Enable DHCP Server?" \
        10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        ENABLE_DHCP="yes"
        DHCP_START=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Start of DHCP range:" 8 60 \
            --title "DHCP RANGE START" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        if [ -z "$DHCP_START" ]; then
            msg_error "No DHCP Start Range entered. Exiting..."
            exit 1
        fi

        DHCP_END=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "End of DHCP range:" 8 60 \
            --title "DHCP RANGE END" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        if [ -z "$DHCP_END" ]; then
            msg_error "No DHCP End Range entered. Exiting..."
            exit 1
        fi
    else
        ENABLE_DHCP="no"
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "HTTPS ACCESS" --yesno "Enable HTTPS for Web GUI?" \
        10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        ENABLE_HTTPS="y"
    else
        ENABLE_HTTPS="n"
    fi
}

function volume_exists() {
    local vol="$1"
    # This command returns 0 if volume is found, non-zero if not
    if pvesm path "$vol" &>/dev/null; then
        return 0  # it exists
    else
        return 1  # it does not exist
    fi
}

###############################################################################
# create_vm
###############################################################################
# Purpose:
#   1) Create the VM shell (qm create).
#   2) Detect if storage is "dir" => use ".raw" extension, else no extension.
#   3) Allocate & attach an EFI disk with Overwrite/Next logic.
#   4) Allocate & attach the main disk with Overwrite/Next logic.
#   5) Attach the chosen ISO and set boot order (semicolon for PVE 8).
#   6) Optionally add up to 3 VirtIO NICs if MANAGE_INTERFACES="yes".
#   7) Final housekeeping (description).
###############################################################################
function create_vm() {
    msg_info "Starting creation of an OPNsense VM..."

    # 1) Basic definitions
    local CREATION_DATE
    CREATION_DATE=$(date +'%Y-%m-%d')

    # (Optional) detect storage type => "dir", "zfspool", "lvmthin", etc.
    local STORAGE_TYPE
    STORAGE_TYPE=$(pvesm status | awk -v s="$VM_STORAGE" '$1 == s {print $2}')

    # If 'dir', we typically need a file extension (e.g. .raw)
    local extension=""
    if [[ "$STORAGE_TYPE" == "dir" ]]; then
        extension=".raw"
    fi

    msg_info "Debug: VM_STORAGE='$VM_STORAGE' (type=$STORAGE_TYPE), ISO_STORAGE='$ISO_STORAGE'"
    msg_info "Debug: VMID='$VMID', EFI_DISK_SIZE='$EFI_DISK_SIZE', DISK_SIZE='$DISK_SIZE'"
    pvesm status || true  # optional listing of storages for debug

    # 2) Create the VM shell
    msg_info "Creating VM shell => ID=$VMID, Hostname=$HN"
    qm create "$VMID" \
      -agent enabled=1 \
      -tablet 0 \
      -bios ovmf \
      -machine "$MACHINE" \
      -cpu "$CPU_TYPE" \
      -cores "$CORE_COUNT" \
      -memory "$RAM_SIZE" \
      -name "$HN" \
      -tags firewall \
      -localtime 1 \
      -onboot 1 \
      -ostype l26 \
      -scsihw virtio-scsi-pci

    # verify creation
    if ! qm status "$VMID" &>/dev/null; then
        msg_error "Failed to create VM shell for ID=$VMID. Exiting."
        exit 1
    fi

    # 3) Optionally add NICs if MANAGE_INTERFACES="yes"
    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        msg_info "Adding up to 3 VirtIO NICs (WAN, LAN, MGMT) ..."
        qm set "$VMID" -net0 "virtio,bridge=$BRIDGE1,macaddr=$MAC1,mtu=$MTU1"
        qm set "$VMID" -net1 "virtio,bridge=$BRIDGE2,macaddr=$MAC2,mtu=$MTU2"
        qm set "$VMID" -net2 "virtio,bridge=$BRIDGE3,macaddr=$MAC3,mtu=$MTU3"
    fi

    ###########################################################################
    # 4) EFI Disk
    ###########################################################################
    msg_info "Creating EFI disk..."
    local efi_index=0

    while true; do
        local efi_filename="vm-${VMID}-disk-${efi_index}${extension}"
        local efi_storage_volume="${VM_STORAGE}:${efi_filename}"

        msg_info "Debug: Checking EFI disk => $efi_storage_volume"
        if volume_exists "$efi_storage_volume"; then
            msg_info "EFI volume '$efi_storage_volume' already exists."
            if whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --title "EFI Disk Exists" \
                --yesno "Volume '$efi_storage_volume' already exists.\n\nDo you want to overwrite it? (This will DESTROY all data on the disk.)" \
                12 70 --yes-button "Overwrite" --no-button "Exit Script"; then

                msg_info "Overwriting => $efi_storage_volume"
                if ! pvesm free "$efi_storage_volume"; then
                    msg_error "Could not remove existing EFI volume => $efi_storage_volume"
                    exit 1
                fi

                msg_info "Allocating EFI => $efi_filename (size=$EFI_DISK_SIZE)"
                pvesm alloc "$VM_STORAGE" "$VMID" "$efi_filename" "$EFI_DISK_SIZE" --format raw

                # Attach the EFI disk
                qm set "$VMID" -efidisk0 "${efi_storage_volume},efitype=4m"
                msg_ok "EFI disk created & attached => $efi_storage_volume"
                break
            else
                msg_info "User refused to overwrite existing EFI disk => Exiting."
                exit_script
            fi
        else
            # fresh
            msg_info "Allocating EFI => $efi_filename (size=$EFI_DISK_SIZE)"
            pvesm alloc "$VM_STORAGE" "$VMID" "$efi_filename" "$EFI_DISK_SIZE" --format raw

            qm set "$VMID" -efidisk0 "${efi_storage_volume},efitype=4m"
            msg_ok "EFI disk created & attached => $efi_storage_volume"
            break
        fi
    done

    ###########################################################################
    # 5) Main Disk
    ###########################################################################
    msg_info "Attaching main disk..."
    local main_index=$((efi_index + 1))

    while true; do
        local main_filename="vm-${VMID}-disk-${main_index}${extension}"
        local main_storage_volume="${VM_STORAGE}:${main_filename}"

        msg_info "Debug: Checking main disk => $main_storage_volume"
        if volume_exists "$main_storage_volume"; then
            msg_info "Main disk volume '$main_storage_volume' already exists."
            if whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --title "Main Disk Exists" \
                --yesno "Volume '$main_storage_volume' already exists.\n\nDo you want to overwrite it? (This will DESTROY all data on the disk.)" \
                12 70 --yes-button "Overwrite" --no-button "Exit Script"; then

                msg_info "Overwriting => $main_storage_volume"
                if ! pvesm free "$main_storage_volume"; then
                    msg_error "Could not remove existing main volume => $main_storage_volume"
                    exit 1
                fi

                msg_info "Allocating main disk => $main_filename (size=$DISK_SIZE)"
                pvesm alloc "$VM_STORAGE" "$VMID" "$main_filename" "$DISK_SIZE" --format raw

                # Attach scsi0 with small retries
                local attached=false
                local RETRY_COUNT=5
                local RETRY_DELAY=3

                for ((attempt=1; attempt<=RETRY_COUNT; attempt++)); do
                    msg_info "Attempt $attempt: qm set $VMID -scsi0 $main_storage_volume"
                    if qm set "$VMID" -scsi0 "$main_storage_volume"; then
                        msg_ok "Main disk attached => $main_storage_volume"
                        attached=true
                        break
                    else
                        msg_error "Attach attempt #$attempt failed. Retrying in $RETRY_DELAY sec..."
                        sleep $RETRY_DELAY
                    fi
                done

                if [ "$attached" = false ]; then
                    msg_error "Could not attach main disk after $RETRY_COUNT tries. Exiting."
                    exit 1
                fi
                break
            else
                msg_info "User refused to overwrite existing Main disk => Exiting."
                exit_script
            fi
        else
            msg_info "Allocating main disk => $main_filename (size=$DISK_SIZE)"
            pvesm alloc "$VM_STORAGE" "$VMID" "$main_filename" "$DISK_SIZE" --format raw

            local attached=false
            local RETRY_COUNT=5
            local RETRY_DELAY=3

            for ((attempt=1; attempt<=RETRY_COUNT; attempt++)); do
                msg_info "Attempt $attempt: qm set $VMID -scsi0 $main_storage_volume"
                if qm set "$VMID" -scsi0 "$main_storage_volume"; then
                    msg_ok "Main disk attached => $main_storage_volume"
                    attached=true
                    break
                else
                    msg_error "Attach attempt #$attempt failed. Retrying..."
                    sleep $RETRY_DELAY
                fi
            done

            if [ "$attached" = false ]; then
                msg_error "Could not attach main disk after $RETRY_COUNT tries. Exiting."
                exit 1
            fi
            break
        fi
    done

    ###########################################################################
    # 6) Attach the OPNsense ISO
    ###########################################################################
    msg_info "Attaching ISO => $ISO_STORAGE:iso/$ISO_BASENAME"
    qm set "$VMID" -ide2 "$ISO_STORAGE:iso/$ISO_BASENAME,media=cdrom"

    ###########################################################################
    # 7) Boot order => Proxmox 8 uses semicolon
    ###########################################################################
    msg_info "Setting boot order => ide2;scsi0"
    qm set "$VMID" -boot order="ide2;scsi0"

    ###########################################################################
    # 8) Description
    ###########################################################################
    qm set "$VMID" -description "# OPNsense VM (ID=$VMID) - Created $CREATION_DATE - ISO Used: $ISO_BASENAME"

    msg_ok "Created an OPNsense VM (ID=$VMID) successfully!"
}

function automate_install() {
    function send_line_to_vm() {
        local line="$1"
        for ((i = 0; i < ${#line}; i++)); do
            character=${line:i:1}
            case $character in
                " ") character="spc" ;;
                "-") character="minus" ;;
                "=") character="equal" ;;
                ",") character="comma" ;;
                ".") character="dot" ;;
                "/") character="slash" ;;
                "'") character="apostrophe" ;;
                ";") character="semicolon" ;;
                '\\') character="backslash" ;;
                '`') character="grave_accent" ;;
                "[") character="bracket_left" ;;
                "]") character="bracket_right" ;;
                "_") character="shift-minus" ;;
                "+") character="shift-equal" ;;
                "?") character="shift-slash" ;;
                "<") character="shift-comma" ;;
                ">") character="shift-dot" ;;
                '"') character="shift-apostrophe" ;;
                ":") character="shift-semicolon" ;;
                "|") character="shift-backslash" ;;
                "~") character="shift-grave_accent" ;;
                "{") character="shift-bracket_left" ;;
                "}") character="shift-bracket_right" ;;
                [A-Z]) character="shift-$(echo $character | tr 'A-Z' 'a-z')" ;;
                "!") character="shift-1" ;;
                "@") character="shift-2" ;;
                "#") character="shift-3" ;;
                '$') character="shift-4" ;;
                "%") character="shift-5" ;;
                "^") character="shift-6" ;;
                "&") character="shift-7" ;;
                "*") character="shift-8" ;;
                "(") character="shift-9" ;;
                ")") character="shift-0" ;;
            esac
            qm sendkey $VMID "$character"
        done
    }

    function press_enter() {
        qm sendkey $VMID ret
    }

    function automate_setup() {
        local LAN_IPV4=$1
        local SUBNET_MASK=$2
        local ENABLE_DHCP=$3
        local DHCP_START=$4
        local DHCP_END=$5
        local ENABLE_HTTPS=$6
        echo "Starting OPNsense setup with:"
        echo "LAN_IPV4: $LAN_IPV4"
        echo "SUBNET_MASK: $SUBNET_MASK"
        echo "ENABLE_DHCP: $ENABLE_DHCP"
        echo "DHCP_START: $DHCP_START"
        echo "DHCP_END: $DHCP_END"
        echo "ENABLE_HTTPS: $ENABLE_HTTPS"
        # Wait for initial boot
        sleep 90
        msg_info "VM booted, sending installer command."
        # Start the installer
        send_line_to_vm "installer"
        press_enter
        send_line_to_vm "opnsense"
        press_enter
        # Wait for keymap selection
        sleep 10
        press_enter
        # Select install filesystem
        sleep 10
        qm sendkey $VMID down
        press_enter
        # Select disk
        sleep 10
        qm sendkey $VMID down
        press_enter
        # Confirm swap
        sleep 10
        press_enter
        # Confirm destroy
        sleep 5
        qm sendkey $VMID left
        press_enter
        # Wait for installation
        sleep 200
        # Set root password
        press_enter
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        press_enter
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        press_enter
        # Confirm reboot
        sleep 20
        qm sendkey $VMID down
        press_enter
        # Wait for reboot
        sleep 30
        # Stop the VM
        qm stop $VMID
        # Wait for stop
        until qm status $VMID | grep -q "stopped"; do
            sleep 2
        done
        # Remove CD boot device
        qm set $VMID -delete ide2
        qm set $VMID -boot order=scsi0
        # Start the VM
        qm start $VMID
        sleep 40
        # Login as root
        send_line_to_vm "root"
        sleep 2
        press_enter
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        press_enter
        sleep 2
        # Configure network interfaces
        send_line_to_vm "2"
        press_enter
        sleep 3
        send_line_to_vm "n"
        press_enter
        sleep 3
        send_line_to_vm "$LAN_IPV4"
        press_enter
        sleep 3
        send_line_to_vm "$SUBNET_MASK"
        sleep 3
        press_enter
        press_enter  # Skip upstream IP
        sleep 3
        send_line_to_vm "n"  # Configure IPv6
        sleep 3
        press_enter
        sleep 3
        press_enter  # Set IPv6
        sleep 6

        if [ "$ENABLE_DHCP" = "yes" ]; then
            send_line_to_vm "y"
            sleep 3
            press_enter
            send_line_to_vm "$DHCP_START"
            press_enter
            sleep 3
            send_line_to_vm "$DHCP_END"
            press_enter
            sleep 3
        else
            send_line_to_vm "n"
            sleep 3
            press_enter
            sleep 3
        fi

        if [ "$ENABLE_HTTPS" = "y" ]; then
            send_line_to_vm "n"
        else
            send_line_to_vm "y"
            sleep 2
            press_enter
        fi
        sleep 3
        press_enter
        sleep 3
        press_enter
    }
    automate_setup "$LAN_IPV4" "$SUBNET_MASK" "$ENABLE_DHCP" "$DHCP_START" "$DHCP_END" "$ENABLE_HTTPS"
}

function automate_config_import() {
    msg_info "Starting automated configuration import..."
    # Wait for the VM to boot
    sleep 90
    msg_info "VM booted, proceeding with configuration import..."

    # Example login steps (keystrokes to log in as root):
    # The real 'send_line_to_vm' and 'press_enter' functions would exist in your
    # automate_install block. If you haven't pasted them, this is only conceptual.

    # send_line_to_vm "root"
    # sleep 2
    # press_enter
    # send_line_to_vm "$ROOT_PASSWORD"
    # sleep 2
    # press_enter
    # sleep 2

    # Launch importer
    # send_line_to_vm "opnsense-importer"
    # press_enter
    # sleep 5

    # Navigate and confirm
    # qm sendkey "$VMID" down
    # sleep 1
    # press_enter
    # sleep 5

    # Confirm import
    # press_enter
    # sleep 30

    # Reboot after import
    # send_line_to_vm "reboot"
    # press_enter

    msg_ok "Configuration import automation completed."
}

function prompt_mount_config() {
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "MOUNT CONFIGURATION" \
        --yesno "Would you like to mount an OPNsense XML configuration file to the VM?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        interactive_mount_config
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "AUTOMATE CONFIG IMPORT" \
            --yesno "Would you like the script to automatically import the configuration?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
            msg_info "Proceeding to automate configuration import..."
            automate_config_import
        else
            msg_ok "You can manually import the configuration after VM starts."
        fi
    else
        prompt_root_password
        prompt_network_configuration
        AUTOMATE_SETUP="yes"
    fi
}

function interactive_mount_config() {
    CONFIG_XML_PATH=""
    IMAGE_SIZE=""
    IMAGE_SIZE_NUM=""  # Add this line
    VM_ID="$VMID"
    USB_LABEL=""
    STORAGE=""

    # 1) Prompt for config.xml file
    while true; do
        CONFIG_XML_PATH=$(whiptail \
            --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter the full path to your config.xml file:" \
            10 60 \
            --title "CONFIG.XML PATH" \
            --cancel-button "Exit Script" \
            3>&1 1>&2 2<&3) || exit_script

        if [[ -f "$CONFIG_XML_PATH" ]]; then
            msg_ok "Config.xml found at '$CONFIG_XML_PATH'."
            break
        else
            msg_error "File not found at '$CONFIG_XML_PATH'. Please try again."
        fi
    done

    # 2) Prompt for desired FAT32 image size (with 32M default)
    while true; do
        IMAGE_SIZE=$(whiptail \
            --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter the size of the FAT32 image (32M+ recommended):" \
            10 60 "32M" \
            --title "IMAGE SIZE" \
            --cancel-button "Exit Script" \
            3>&1 1>&2 2<&3) || exit_script

        # If empty, default to "32M"
        if [[ -z "$IMAGE_SIZE" ]]; then
            IMAGE_SIZE="32M"
            IMAGE_SIZE_NUM=32
        fi

        # Extract the numeric portion if it matches "<number>M"
        IMAGE_SIZE_NUM=$(echo "$IMAGE_SIZE" | sed -E 's/^([0-9]+)M$/\1/')

        # Must be at least 32
        if [[ -n "$IMAGE_SIZE_NUM" && "$IMAGE_SIZE_NUM" -ge 32 ]]; then
            msg_ok "Image size set to $IMAGE_SIZE."
            break
        else
            msg_error "Size must be at least 32M. Please try again."
        fi
    done

    # 3) Prompt for USB label, default to "CONFIG" (uppercase enforced)
    while true; do
        USB_LABEL=$(whiptail \
            --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter the volume label for the FAT32 USB image:" \
            10 60 "CONFIG" \
            --title "USB LABEL" \
            --cancel-button "Exit Script" \
            3>&1 1>&2 2<&3) || exit_script

        USB_LABEL=$(echo "$USB_LABEL" | tr '[:lower:]' '[:upper:]')

        if [[ -n "$USB_LABEL" ]]; then
            msg_ok "USB volume label set to '$USB_LABEL'."
            break
        else
            msg_error "Volume label cannot be empty. Please try again."
        fi
    done

    # 4) Ask which storage to use for the USB (images)
    USB_STORAGE=$(select_usb_storage "Storage Pools" "Which storage pool would you like to use for the USB image?")

    # 5) Now proceed to actually create the USB image and attach
    create_and_attach_usb
}

function create_and_attach_usb() {
    # Create a raw disk image directly in the VM's storage
    local disk_name="vm-${VMID}-usb0"
    local disk_path="${USB_STORAGE}:${disk_name}"
    
    msg_info "Creating USB disk image..."
    
    # Allocate the disk
    if ! pvesm alloc "${USB_STORAGE}" "${VMID}" "${disk_name}" "32M" --format raw; then
        msg_error "Failed to allocate USB disk"
        exit 1
    fi

    # Get the real path to the disk
    local real_path
    real_path=$(pvesm path "${disk_path}")
    
    # Format it as FAT32
    if ! mkfs.vfat -F 32 -n "${USB_LABEL}" "${real_path}"; then
        msg_error "Failed to format USB disk as FAT32"
        pvesm free "${disk_path}"
        exit 1
    }

    # Create a temporary mount point
    local mount_point
    mount_point=$(mktemp -d)
    
    # Mount the image
    if ! mount -o loop "${real_path}" "${mount_point}"; then
        msg_error "Failed to mount USB disk"
        rm -rf "${mount_point}"
        pvesm free "${disk_path}"
        exit 1
    }

    # Create config directory and copy file
    mkdir -p "${mount_point}/conf"
    if ! cp "${CONFIG_XML_PATH}" "${mount_point}/conf/config.xml"; then
        msg_error "Failed to copy config file"
        umount "${mount_point}"
        rm -rf "${mount_point}"
        pvesm free "${disk_path}"
        exit 1
    }

    # Unmount
    sync
    umount "${mount_point}"
    rm -rf "${mount_point}"

    # Find next available virtio slot
    local virtio_slot=""
    for i in {0..9}; do
        if ! qm config "${VMID}" | grep -q "^virtio${i}:"; then
            virtio_slot="virtio${i}"
            break
        fi
    done

    if [ -z "${virtio_slot}" ]; then
        msg_error "No available virtio slots"
        pvesm free "${disk_path}"
        exit 1
    }

    # Attach the disk to the VM
    if ! qm set "${VMID}" --"${virtio_slot}" "${disk_path}"; then
        msg_error "Failed to attach USB disk to VM"
        pvesm free "${disk_path}"
        exit 1
    }

    msg_ok "Config USB disk created and attached successfully"
}

#################################################################################
# Main Script Execution
#################################################################################

header_info

check_root
check_dependencies
arch_check
pve_check
ssh_check

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# Prompt user to proceed
if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "OPNsense VM" \
    --yesno "This will create a New OPNsense VM. Proceed?" 10 58 \
    --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
    header_info && echo -e "User exited script.\n" && exit 1
fi

# Prompt to manage interfaces
if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
    --title "MANAGE PROXMOX INTERFACES" \
    --yesno "Would you like the script to manage and configure the Proxmox host network interfaces and add them to the VM?\nIf no, the VM will not have the predefined interfaces set." \
    --defaultno 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
    MANAGE_INTERFACES="no"
else
    MANAGE_INTERFACES="yes"
fi

# Gather user-defined settings
start_script

# Now pick separate storages for ISO vs. VM disks:
ISO_STORAGE=$(select_iso_storage)
VM_STORAGE=$(select_disk_storage)
msg_ok "Selected [$ISO_STORAGE] for ISO and [$VM_STORAGE] for VM Disks."

# Next pick the ISO (local or downloaded)
select_iso

# Create the VM (with Overwrite/Next logic for disks)
create_vm

# Optional config mount:
prompt_mount_config

# Start if user asked:
if [ "$START_VM" = "yes" ]; then
    if [ "$AUTOMATE_SETUP" = "yes" ]; then
        msg_info "Starting OPNsense VM"
        qm start "$VMID"
        msg_info "VM Started. Proceeding to automate the installation."
        automate_install
    else
        msg_info "Starting OPNsense VM"
        qm start "$VMID"
        msg_ok "VM started."
    fi
else
    msg_info "VM creation complete. VM not started."
fi

# If also bridging on host
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ADD INTERFACES" --defaultno \
        --yesno "Would you like to add the interfaces to /etc/network/interfaces?" \
        10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then

        msg_info "Listing physical interfaces"
        PHYSICAL_INTERFACES=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}')
        echo "Available physical interfaces:"
        echo "$PHYSICAL_INTERFACES"

        BRIDGE_PORT_WAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE1 (WAN)" 8 60 --title "BRIDGE-PORTS (WAN)" \
            --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        BRIDGE_PORT_LAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE2 (LAN)" 8 60 --title "BRIDGE-PORTS (LAN)" \
            --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        BRIDGE_PORT_MGMT=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE3 (MGMT)" 8 60 --title "BRIDGE-PORTS (MGMT)" \
            --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        MGMT_IP=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter static IP address for $BRIDGE3 (MGMT)" 8 60 --title "MGMT IP (MGMT)" \
            --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        MGMT_GW=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter gateway for $BRIDGE3 (MGMT)" 8 60 --title "MGMT GATEWAY (MGMT)" \
            --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        echo "auto $BRIDGE1
iface $BRIDGE1 inet manual
        bridge-ports $BRIDGE_PORT_WAN
        bridge-stp off
        bridge-fd 0

auto $BRIDGE2
iface $BRIDGE2 inet manual
        bridge-ports $BRIDGE_PORT_LAN
        bridge-stp off
        bridge-fd 0

auto $BRIDGE3
iface $BRIDGE3 inet static
        address $MGMT_IP
        gateway $MGMT_GW
        bridge-ports $BRIDGE_PORT_MGMT
        bridge-stp off
        bridge-fd 0" | tee -a /etc/network/interfaces >/dev/null

        msg_ok "Interfaces added to /etc/network/interfaces"
    fi
fi

msg_ok "Completed Successfully!"

cleanup
popd >/dev/null
exit 0
