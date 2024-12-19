#!/usr/bin/env bash
# Purpose: Automate the creation of a Proxmox Backup Server (PBS) VM in Proxmox
# This script will parse the official enterprise.proxmox.com ISO directory listing.
# It will retrieve available PBS ISOs, allow the user to select one (just by pressing Enter on the highlighted line is enough),
# prepend the last updated date (YYYYMMDD) to the filename, and then create a VM using that ISO.
# If parsing fails or no ISOs are found, a fallback URL/ISO is used.
#
# NOTE:
# - Ensure `wget`, `curl`, `whiptail`, and Proxmox CLI tools (qm, pvesm, pvesh) are installed.
# - This script tries to handle changes gracefully, but if the site changes drastically, adjustments may be needed.
#
# Change from previous version:
# Use `--menu` instead of `--radiolist` so user can just hit Enter without pressing Space. The highlighted item will be chosen.

set -euo pipefail

###############################################
#               CONFIGURATION                 #
###############################################
FALLBACK_URL="https://enterprise.proxmox.com/iso/proxmox-backup-server_3.3-1.iso"
FALLBACK_VERSION="3.3-1"
FALLBACK_DATE="20241128"  # YYYYMMDD format for fallback
FALLBACK_FILENAME="${FALLBACK_DATE}-proxmox-backup-server_${FALLBACK_VERSION}.iso"
PBS_DOWNLOAD_DIR="https://enterprise.proxmox.com/iso/"

###############################################
#                 FUNCTIONS                   #
###############################################

function header_info {
    clear
    cat <<"EOF"
 __                          __                         __         
 )_) _ _      _ _   _        )_)  _   _ ( _      _     (_ ` _    _ 
/   ) (_) \) ) ) ) (_) \)   /__) (_( (_  )\ (_( )_)   .__) ) \) )  
          (\           (\                      (                   
                                                                  
Press Enter to Continue
EOF
}

function msg_info() {
    echo -e "\033[1;92mInfo:\033[m $1"
}

function msg_ok() {
    echo -e "\033[1;92m✓\033[m \033[1;92m$1\033[m"
}

function msg_error() {
    echo -e "\033[01;31m✗\033[m \033[01;31m$1\033[m"
}

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n\033[01;31m[ERROR]\033[m at line $line_number: exit code $exit_code, while executing: $command\n"
    cleanup_vmid
    exit $exit_code
}

function cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

function cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" &>/dev/null || true
  fi
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

function check_dependencies() {
    for cmd in whiptail pvesh pvesm qm wget curl; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "Required command '$cmd' is not installed."
            exit 1
        fi
    done
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

function arch_check() {
    if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
        msg_error "This script will not work with PiMox!"
        echo -e "Exiting..."
        sleep 2
        exit 1
    fi
}

function pve_check() {
    local required_version="8.1"
    local current_version
    current_version=$(pveversion | grep pve-manager | sed -E 's/.*pve-manager\/([0-9.]+).*/\1/')
    if [[ $(printf "%s\n%s" "$required_version" "$current_version" | sort -V | head -n1) != "$required_version" ]]; then
        msg_error "Proxmox VE version $current_version is older than required version $required_version."
        echo -e "Please upgrade Proxmox before running this script."
        exit 1
    fi
}

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" ]]; then
        if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
          --defaultno \
          --title "SSH DETECTED" \
          --yesno "It's recommended to use the Proxmox shell instead of SSH. Continue anyway?" 10 62; then
            clear
            exit 1
        fi
    fi
}

function exit_script() {
    clear
    echo -e "User exited script.\n"
    exit 1
}

function check_vmid() {
    NEXTID=300
    while pvesh get /cluster/resources --type vm | grep -qw "$NEXTID"; do
        ((NEXTID++))
    done
}

function generate_mac() {
    echo "02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
}

function default_settings() {
    check_vmid
    VMID="$NEXTID"
    MACHINE="q35"
    DISK_CACHE=""
    HN="PBS-VM${VMID}"
    CPU_TYPE="host"
    CORE_COUNT="2"
    RAM_SIZE="2048"
    DISK_SIZE="30G"
    BRG="vmbr0"
    MAC=$(generate_mac)
    VLAN=""
    MTU="1500"
    START_VM="yes"
    VM_TAG="backup"
    EFI_DISK_SIZE="512M"
    msg_ok "Default settings applied."
}

function advanced_settings() {
    check_vmid
    VMID=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Virtual Machine ID (Default: $NEXTID)" 8 60 "$NEXTID" \
      --title "VIRTUAL MACHINE ID" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    HN=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Hostname (Default: PBS-VM$VMID)" 8 60 "PBS-VM${VMID}" \
      --title "HOSTNAME" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    MACHINE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --title "MACHINE TYPE" --radiolist "Select machine type:" 10 60 2 \
      "q35" "Q35: Modern with PCIe support (recommended)" ON \
      "i440fx" "Older, less feature-rich" OFF \
      3>&1 1>&2 2<&3) || exit_script

    DISK_CACHE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --title "DISK CACHE" --radiolist "Disk cache type:" 10 60 2 \
      "none" "None (recommended)" ON \
      "writeback" "Better performance, riskier" OFF \
      3>&1 1>&2 2<&3) || exit_script

    CPU_TYPE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --title "CPU MODEL" --radiolist "CPU model:" 10 60 2 \
      "host" "Use host CPU features" ON \
      "kvm64" "Generic" OFF \
      3>&1 1>&2 2<&3) || exit_script

    CORE_COUNT=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Number of CPU cores (Default: 2)" 8 60 "2" \
      --title "CPU CORES" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    RAM_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "RAM size in MiB (Default: 2048)" 8 60 "2048" \
      --title "RAM SIZE" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    DISK_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Disk size (Default: 30G)" 8 60 "30G" \
      --title "DISK SIZE" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    BRG=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Network Bridge (Default: vmbr0)" 8 60 "vmbr0" \
      --title "NETWORK BRIDGE" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    MAC=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "MAC Address (Auto-generated)" 8 60 "$(generate_mac)" \
      --title "MAC ADDRESS" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    VLAN=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "VLAN Tag (Optional)" 8 60 \
      --title "VLAN TAG" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    MTU=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "Interface MTU Size (Default: 1500)" 8 60 "1500" \
      --title "MTU SIZE" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    VM_TAG=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "VM Tag (Default: backup)" 8 60 "backup" \
      --title "VM TAG" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    EFI_DISK_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --inputbox "EFI Disk Size (Default: 512M)" 8 60 "512M" \
      --title "EFI DISK SIZE" --cancel-button exit_script 3>&1 1>&2 2<&3) || exit_script

    if whiptail --backtitle "Proxmox VE PBS Install Script" \
       --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 60; then
      START_VM="yes"
    else
      START_VM="no"
    fi

    msg_ok "Advanced settings applied."
}

function start_script() {
    if whiptail --backtitle "Proxmox VE PBS Install Script" --title "SETTINGS" --yesno "Use Default Settings?" --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

header_info
read -r

if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
  --title "Proxmox Backup Server VM" \
  --yesno "This will create a new PBS VM. Proceed?" 10 58; then
  header_info && echo -e "User exited script.\n" && exit 1
fi

check_root
check_dependencies
arch_check
pve_check
ssh_check
start_script

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

#########################################
# Parse available PBS ISOs from directory
#########################################
msg_info "Attempting to parse available PBS ISOs from $PBS_DOWNLOAD_DIR"
HTML_CONTENT=$(curl -s "$PBS_DOWNLOAD_DIR" || true)

ISO_ENTRIES=()
while IFS= read -r line; do
    # Looking for lines with proxmox-backup-server_*.iso
    if [[ "$line" =~ href=\"(proxmox-backup-server_[0-9]+\.[0-9]+-[0-9]+\.iso)\" ]]; then
        ISO_FILE="${BASH_REMATCH[1]}"
        DATE_PART=$(echo "$line" | sed -E 's#.*\.iso</a>[[:space:]]+([0-9]{2}-[A-Za-z]{3}-[0-9]{4}).*#\1#' || true)
        if [[ -z "$DATE_PART" ]]; then
            DATE_PART=$(date +"%d-%b-%Y")
        fi
        DD=$(echo "$DATE_PART" | cut -d'-' -f1)
        Mon=$(echo "$DATE_PART" | cut -d'-' -f2)
        YYYY=$(echo "$DATE_PART" | cut -d'-' -f3)
        case $Mon in
          Jan) MM="01" ;;
          Feb) MM="02" ;;
          Mar) MM="03" ;;
          Apr) MM="04" ;;
          May) MM="05" ;;
          Jun) MM="06" ;;
          Jul) MM="07" ;;
          Aug) MM="08" ;;
          Sep) MM="09" ;;
          Oct) MM="10" ;;
          Nov) MM="11" ;;
          Dec) MM="12" ;;
          *) MM="01" ;;
        esac
        DATE_YMD="${YYYY}${MM}${DD}"
        NEW_FILENAME="${DATE_YMD}-${ISO_FILE}"
        ISO_URL="${PBS_DOWNLOAD_DIR}${ISO_FILE}"
        ISO_ENTRIES+=("$ISO_URL|$NEW_FILENAME|$DATE_PART")
    fi
done < <(echo "$HTML_CONTENT")

MENU_ITEMS=()
if [ ${#ISO_ENTRIES[@]} -eq 0 ]; then
    msg_info "No PBS ISO found. Adding fallback to list."
    MENU_ITEMS+=("$FALLBACK_URL" "Fallback PBS ISO: $FALLBACK_FILENAME - Last Updated: ${FALLBACK_DATE}")
else
    # Add found ISOs
    for entry in "${ISO_ENTRIES[@]}"; do
        IFS='|' read -r IURL IFN IDATE <<< "$entry"
        MENU_ITEMS+=("$IURL" "$IFN - Last Updated: $IDATE")
    done
    # Add fallback as well
    MENU_ITEMS+=("$FALLBACK_URL" "$FALLBACK_FILENAME - Last Updated: ${FALLBACK_DATE} (Fallback)")
fi

###############################################
# ISO selection step using --menu
###############################################
if whiptail --backtitle "Proxmox VE PBS Install Script" \
  --title "ISO SELECTION" \
  --yesno "Would you like to download a PBS ISO from the internet?\nChoose 'No' to select a locally available ISO." 10 60; then

    CHOSEN_ISO_URL=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --title "Available PBS ISOs" \
      --menu "Select an ISO to download:\nUse Arrow keys to highlight and Enter to select." \
      20 100 8 \
      "${MENU_ITEMS[@]}" 3>&1 1>&2 2<&3) || exit_script

    # If user presses Enter without changing anything, CHOSEN_ISO_URL should be the top one by default
    # If user cancels, we exit_script
    # If user is forced to choose one line and press enter, that line is chosen.

    # No need to check for empty here, if user pressed Enter, we got something.

    ISO_BASENAME=""
    if [ "$CHOSEN_ISO_URL" = "$FALLBACK_URL" ]; then
        ISO_BASENAME="$FALLBACK_FILENAME"
    else
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r IURL IFN IDATE <<< "$entry"
            if [ "$IURL" = "$CHOSEN_ISO_URL" ]; then
                ISO_BASENAME="$IFN"
                break
            fi
        done
        if [ -z "$ISO_BASENAME" ]; then
            ISO_BASENAME="$FALLBACK_FILENAME"
        fi
    fi

    ISO_PATH="/var/lib/vz/template/iso/$ISO_BASENAME"

    if [ -f "$ISO_PATH" ]; then
        msg_ok "ISO file already exists: $ISO_BASENAME"
    else
        msg_info "Downloading PBS ISO"
        if ! wget -q --show-progress "$CHOSEN_ISO_URL" -O "$ISO_PATH"; then
            msg_error "Failed to download PBS ISO."
            if whiptail --backtitle "Proxmox VE PBS Install Script" --title "LOCAL ISO" \
              --yesno "Download failed. Select a locally available ISO?" 10 60; then

                ISO_LIST=()
                while IFS= read -r iso_file; do
                  ISO_LIST+=("$(basename "$iso_file")" "")
                done < <(find /var/lib/vz/template/iso -type f -name "*.iso")

                if [ ${#ISO_LIST[@]} -eq 0 ]; then
                    msg_error "No .iso files found in /var/lib/vz/template/iso."
                    exit 1
                fi

                CHOSEN_LOCAL_ISO=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
                  --title "Local ISO Files" \
                  --menu "Select a local ISO file:" 16 60 6 \
                  "${ISO_LIST[@]}" 3>&1 1>&2 2<&3)
                if [ -z "${CHOSEN_LOCAL_ISO}" ]; then
                    msg_error "No ISO selected. Exiting..."
                    exit 1
                fi
                ISO_PATH="/var/lib/vz/template/iso/$CHOSEN_LOCAL_ISO"
                ISO_BASENAME="$CHOSEN_LOCAL_ISO"
                msg_ok "Using local ISO: $ISO_BASENAME"
            else
                msg_error "Exiting due to inability to retrieve ISO."
                exit 1
            fi
        else
            echo -en "\e[1A\e[0K"
            msg_ok "Downloaded $ISO_BASENAME"
        fi
    fi
else
    # User chose local ISO
    ISO_LIST=()
    while IFS= read -r iso_file; do
        ISO_LIST+=("$(basename "$iso_file")" "")
    done < <(find /var/lib/vz/template/iso -type f -name "*.iso")

    if [ ${#ISO_LIST[@]} -eq 0 ]; then
        msg_error "No .iso files found in /var/lib/vz/template/iso."
        exit 1
    fi

    CHOSEN_LOCAL_ISO=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
      --title "Local ISO Files" \
      --menu "Select a local ISO file:" 16 60 6 \
      "${ISO_LIST[@]}" 3>&1 1>&2 2<&3) || exit_script

    if [ -z "${CHOSEN_LOCAL_ISO}" ]; then
        msg_error "No ISO selected. Exiting..."
        exit 1
    fi
    ISO_PATH="/var/lib/vz/template/iso/$CHOSEN_LOCAL_ISO"
    ISO_BASENAME="$CHOSEN_LOCAL_ISO"
    msg_ok "Using local ISO: $ISO_BASENAME"
fi

###############################################
#              CREATE THE VM                  #
###############################################
msg_info "Validating Storage"
STORAGE_MENU=()
while read -r line; do
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')
    ITEM="Type: $TYPE Free: $FREE"
    STORAGE_MENU+=("$TAG" "$ITEM")
done < <(pvesm status -content images | awk 'NR>1')

if [[ ${#STORAGE_MENU[@]} -eq 0 ]]; then
  msg_error "Unable to detect a valid storage location."
  exit 1
fi

STORAGE=$(whiptail --backtitle "Proxmox VE PBS Install Script" --title "Storage Pools" --menu \
  "Which storage pool would you like to use for ${HN}?\nUse Arrow keys and Enter to select." \
  16 80 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2<&3)

if [[ -z "$STORAGE" ]]; then
  # If user didn't choose, pick the first one
  STORAGE="${STORAGE_MENU[0]}"
fi

msg_ok "Using $STORAGE for Storage Location."
msg_ok "Virtual Machine ID is $VMID."

msg_info "Creating a PBS VM"
qm create "$VMID" \
  -agent enabled=1 \
  -tablet 0 \
  -localtime 1 \
  -bios ovmf \
  -machine "$MACHINE" \
  -cpu "$CPU_TYPE" \
  -cores "$CORE_COUNT" \
  -memory "$RAM_SIZE" \
  -name "$HN" \
  -tags "$VM_TAG" \
  -net0 "virtio,bridge=$BRG,macaddr=$MAC${VLAN:+,vlan-tag=$VLAN}${MTU:+,mtu=$MTU}" \
  -onboot 1 \
  -ostype l26 \
  -scsihw virtio-scsi-pci

if ! qm status "$VMID" &>/dev/null; then
  msg_error "Failed to create VM $VMID. Exiting."
  exit 1
fi

msg_info "Creating EFI disk"
qm set "$VMID" -efidisk0 "${STORAGE}:0,size=${EFI_DISK_SIZE},efitype=4m"

msg_info "Attaching disks and ISO"
msg_info "Allocating disk space"
DISK0="vm-${VMID}-disk-1"
pvesm alloc "$STORAGE" "$VMID" "$DISK0" "$DISK_SIZE"

RETRY_COUNT=5
RETRY_DELAY=5
for (( i=1; i<=RETRY_COUNT; i++ )); do
  if qm set "$VMID" -scsi0 "${STORAGE}:${DISK0}"${DISK_CACHE:+,cache=${DISK_CACHE}}; then
    msg_ok "Main disk attached successfully"
    break
  else
    msg_error "Attempt $i: Failed to attach main disk. Retrying in $RETRY_DELAY seconds..."
    sleep $RETRY_DELAY
  fi

  if [[ $i -eq $RETRY_COUNT ]]; then
    msg_error "Exceeded maximum retry attempts to attach main disk. Exiting."
    exit 1
  fi
done

qm set "$VMID" -ide2 "local:iso/$ISO_BASENAME,media=cdrom"
msg_info "Setting boot order"
qm set "$VMID" -boot order=ide2;order=scsi0

CREATION_DATE=$(date +"%Y-%m-%d")
ISO_USED="$ISO_BASENAME"
qm set "$VMID" \
  -description "# PBS - VM - $VMID - Created $CREATION_DATE - ISO Used: $ISO_USED</div><div align='center'><a href='https://www.proxmox.com/en/proxmox-backup-server' target='_blank' rel='noopener noreferrer'><img src='https://www.proxmox.com/images/proxmox/Proxmox_logo_standard_hex_400px.png'/></a><br><br>"

msg_ok "Created a PBS VM (${HN})"

if (whiptail --backtitle "Proxmox VE PBS Install Script" --title "START VIRTUAL MACHINE" --yesno "Would you like to start the VM now?" 10 60); then
  msg_info "Starting PBS VM"
  qm start "$VMID"
  msg_ok "Started PBS VM"

  whiptail --backtitle "Proxmox VE PBS Install Script" --title "INSTALL PBS" --msgbox "Install Proxmox Backup Server to the VM now. When complete, press Enter." 10 60
  if (whiptail --backtitle "Proxmox VE PBS Install Script" --title "REMOVE CD DRIVE" --yesno "Remove Mounted CD drive device from VM and set boot to VM drive?" 10 60); then
    qm stop "$VMID"
    msg_info "Removing CD drive and setting boot to VM drive"
    qm set "$VMID" -delete ide2
    qm set "$VMID" -boot order=scsi0
    qm start "$VMID"
    msg_ok "Removed CD drive and set boot to VM drive"
  else
    msg_info "CD drive not removed. Boot order unchanged."
  fi
else
  msg_info "VM creation complete. VM not started."
fi

msg_ok "Completed Successfully!"
cleanup
