#!/usr/bin/env bash
# Purpose: Automate the creation of a Proxmox Backup Server (PBS) VM in Proxmox
# This script will parse the official enterprise.proxmox.com ISO directory listing,
# retrieve available PBS ISOs, allow user selection, and create a VM using that ISO.
# 
# Features:
# - Automatic ISO discovery from official Proxmox repository
# - Support for local ISO selection
# - Advanced VM configuration options
# - Automatic network bridge validation
# - Smart storage selection
# - Post-installation configuration options
#
# Dependencies: wget, curl, whiptail, Proxmox CLI tools (qm, pvesm, pvesh)

set -euo pipefail

###############################################
#               CONFIGURATION                 #
###############################################

# ISO Configuration
FALLBACK_URL="https://enterprise.proxmox.com/iso/proxmox-backup-server_3.4-1.iso"
FALLBACK_VERSION="3.4-1"
FALLBACK_DATE="20250410"  # YYYYMMDD format for fallback
FALLBACK_FILENAME="${FALLBACK_DATE}-proxmox-backup-server_${FALLBACK_VERSION}.iso"
PBS_DOWNLOAD_DIR="https://enterprise.proxmox.com/iso/"

# Default Network Configuration
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MTU="1500"

# VM ID Range
STARTING_VM_ID=300
NEXTID=$STARTING_VM_ID

# PBS Default Credentials (for reference)
DEFAULT_PBS_USER="root@pam"
DEFAULT_PBS_PASS="proxmox"

###############################################
#              COLOR DEFINITIONS              #
###############################################

CL="\033[m"               # Clear formatting
GN="\033[1;92m"           # Green
RD="\033[01;31m"          # Red
YL="\033[01;33m"          # Yellow
DGN="\033[32m"            # Dark Green
BGN="\033[4;92m"          # Bold Green
BL="\033[36m"             # Blue
CM="${GN}✓${CL}"          # Checkmark
CROSS="${RD}✗${CL}"       # Cross
WARN="${YL}!${CL}"        # Warning
INFO="${BL}◉${CL}"        # Info

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
                                                                  
        P R O X M O X   B A C K U P   S E R V E R   V M
EOF
}

function msg_info() {
    echo -e " ${INFO} ${YL}$1${CL}"
}

function msg_ok() {
    echo -e " ${CM} ${GN}$1${CL}"
}

function msg_error() {
    echo -e " ${CROSS} ${RD}$1${CL}"
}

function msg_warn() {
    echo -e " ${WARN} ${YL}$1${CL}"
}

# Progress indicator function
function show_progress() {
    local duration=$1
    local message=$2
    echo -n " ${INFO} ${YL}${message}${CL} "
    for ((i=0; i<duration; i++)); do
        echo -n "."
        sleep 1
    done
    echo
}

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
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
        msg_info "Cleaning up VM $VMID"
        qm stop "$VMID" &>/dev/null || true
        sleep 2
        qm destroy "$VMID" &>/dev/null || true
    fi
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

###############################################
#           DEPENDENCY CHECKING               #
###############################################

function check_dependencies() {
    local deps=(whiptail pvesh pvesm qm wget curl openssl numfmt)
    local missing_deps=()
    
    msg_info "Checking dependencies..."
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        msg_error "Missing required dependencies: ${missing_deps[*]}"
        msg_info "Install with: apt-get install ${missing_deps[*]}"
        exit 1
    fi
    
    msg_ok "All dependencies satisfied"
}

###############################################
#           SYSTEM VALIDATION                 #
###############################################

function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        clear
        msg_error "This script must be run as root"
        echo -e "\nPlease run: sudo $0"
        exit 1
    fi
}

function arch_check() {
    local arch=$(dpkg --print-architecture)
    if [[ "$arch" != "amd64" ]]; then
        msg_error "This script requires amd64 architecture (current: $arch)"
        msg_warn "PBS is not supported on ARM architectures"
        exit 1
    fi
}

function pve_check() {
    local required_version="8.1"
    local current_version
    
    if ! command -v pveversion &>/dev/null; then
        msg_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    
    current_version=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "0.0")
    
    if [[ $(printf "%s\n%s" "$required_version" "$current_version" | sort -V | head -n1) != "$required_version" ]]; then
        msg_error "Proxmox VE version $current_version is older than required version $required_version"
        msg_info "Please upgrade Proxmox VE before running this script"
        exit 1
    fi
    
    msg_ok "Proxmox VE version $current_version meets requirements"
}

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" ]]; then
        if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's recommended to use the Proxmox shell instead of SSH.\n\nSSH can cause issues with interactive elements.\n\nContinue anyway?" 12 62; then
            clear
            exit 1
        fi
    fi
}

###############################################
#           VM ID MANAGEMENT                  #
###############################################

function get_next_vmid() {
    local try_id=$STARTING_VM_ID
    
    while true; do
        # Check if ID is used by a VM
        if [ -f "/etc/pve/qemu-server/${try_id}.conf" ]; then
            ((try_id++))
            continue
        fi
        
        # Check if ID is used by a container
        if [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
            ((try_id++))
            continue
        fi
        
        # Check cluster resources
        if pvesh get /cluster/resources --type vm 2>/dev/null | grep -qw "$try_id"; then
            ((try_id++))
            continue
        fi
        
        break
    done
    
    echo "$try_id"
}

function check_vmid() {
    NEXTID=$(get_next_vmid)
}

###############################################
#           UTILITY FUNCTIONS                 #
###############################################

function generate_mac() {
    echo "02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
}

function verify_bridge_exists() {
    local bridge="$1"
    
    if ! ip link show "$bridge" &>/dev/null; then
        msg_warn "Bridge '$bridge' does not exist"
        
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "BRIDGE NOT FOUND" \
            --yesno "Bridge '$bridge' does not exist.\n\nWould you like to create it?" 10 60; then
            
            msg_info "Creating bridge $bridge"
            echo -e "\nauto $bridge\niface $bridge inet manual\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
            
            if systemctl restart networking; then
                msg_ok "Bridge $bridge created successfully"
            else
                msg_error "Failed to create bridge. Please create it manually"
                exit 1
            fi
        else
            msg_error "Bridge '$bridge' is required. Please create it manually"
            exit 1
        fi
    fi
}

function exit_script() {
    clear
    echo -e "User exited script.\n"
    exit 1
}

###############################################
#        VM CONFIGURATION SETTINGS            #
###############################################

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
    BRG="$DEFAULT_BRIDGE"
    MAC=$(generate_mac)
    VLAN=""
    MTU="$DEFAULT_MTU"
    START_VM="yes"
    VM_TAG="backup,pbs"
    EFI_DISK_SIZE="512M"
    SERIAL_CONSOLE="yes"
    QEMU_AGENT="yes"
    BALLOON="yes"
    PROTECTION="no"
    
    msg_ok "Default settings applied"
}

function advanced_settings() {
    check_vmid
    
    # VM ID
    VMID=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Virtual Machine ID (Default: $NEXTID)" 8 60 "$NEXTID" \
        --title "VIRTUAL MACHINE ID" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Validate VM ID
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        msg_error "VM ID must be a number"
        exit 1
    fi
    
    # Hostname
    HN=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Hostname (Default: PBS-VM$VMID)" 8 60 "PBS-VM${VMID}" \
        --title "HOSTNAME" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Machine Type
    MACHINE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "MACHINE TYPE" --radiolist "Select machine type:" 10 60 2 \
        "q35" "Q35: Modern with PCIe support (recommended)" ON \
        "i440fx" "i440fx: Legacy compatibility" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # Disk Cache
    DISK_CACHE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "DISK CACHE" --radiolist "Select disk cache mode:" 12 60 4 \
        "none" "None (recommended for integrity)" ON \
        "writeback" "Writeback (better performance)" OFF \
        "writethrough" "Writethrough (balanced)" OFF \
        "directsync" "Direct sync (safest)" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # CPU Type
    CPU_TYPE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "CPU MODEL" --radiolist "Select CPU model:" 12 60 4 \
        "host" "Host (best performance)" ON \
        "kvm64" "KVM64 (compatibility)" OFF \
        "qemu64" "QEMU64 (maximum compatibility)" OFF \
        "max" "Maximum features" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # CPU Cores
    CORE_COUNT=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Number of CPU cores (Default: 2)" 8 60 "2" \
        --title "CPU CORES" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # RAM Size
    RAM_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "RAM size in MiB (Default: 2048)" 8 60 "2048" \
        --title "RAM SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Disk Size
    DISK_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Disk size (Default: 30G)" 8 60 "30G" \
        --title "DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Network Bridge
    BRG=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Network Bridge (Default: $DEFAULT_BRIDGE)" 8 60 "$DEFAULT_BRIDGE" \
        --title "NETWORK BRIDGE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # MAC Address
    MAC=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "MAC Address (Auto-generated)" 8 60 "$(generate_mac)" \
        --title "MAC ADDRESS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # VLAN Tag
    VLAN=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "VLAN Tag (Leave empty for none)" 8 60 "" \
        --title "VLAN TAG" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # MTU Size
    MTU=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "Interface MTU Size (Default: $DEFAULT_MTU)" 8 60 "$DEFAULT_MTU" \
        --title "MTU SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # VM Tags
    VM_TAG=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "VM Tags (comma-separated)" 8 60 "backup,pbs" \
        --title "VM TAGS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # EFI Disk Size
    EFI_DISK_SIZE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --inputbox "EFI Disk Size (Default: 512M)" 8 60 "512M" \
        --title "EFI DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Additional Options
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "SERIAL CONSOLE" --yesno "Enable serial console?" 8 60; then
        SERIAL_CONSOLE="yes"
    else
        SERIAL_CONSOLE="no"
    fi
    
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "QEMU AGENT" --yesno "Enable QEMU Guest Agent?" 8 60; then
        QEMU_AGENT="yes"
    else
        QEMU_AGENT="no"
    fi
    
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "MEMORY BALLOONING" --yesno "Enable memory ballooning?" 8 60; then
        BALLOON="yes"
    else
        BALLOON="no"
    fi
    
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "VM PROTECTION" --yesno "Enable VM protection?" 8 60; then
        PROTECTION="yes"
    else
        PROTECTION="no"
    fi
    
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 60; then
        START_VM="yes"
    else
        START_VM="no"
    fi
    
    msg_ok "Advanced settings configured"
}

function start_script() {
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "SETTINGS" \
        --yesno "Use Default Settings?" --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

###############################################
#           ISO HANDLING                      #
###############################################

function parse_iso_listing() {
    local html_content="$1"
    local iso_entries=()
    
    while IFS= read -r line; do
        # Looking for lines with proxmox-backup-server_*.iso
        if [[ "$line" =~ href=\"(proxmox-backup-server_[0-9]+\.[0-9]+-[0-9]+\.iso)\" ]]; then
            local iso_file="${BASH_REMATCH[1]}"
            
            # Extract date more reliably
            local date_part=$(echo "$line" | grep -oP '\d{2}-[A-Za-z]{3}-\d{4}' | head -1)
            
            if [[ -z "$date_part" ]]; then
                date_part=$(date +"%d-%b-%Y")
            fi
            
            # Parse date components
            local dd=$(echo "$date_part" | cut -d'-' -f1)
            local mon=$(echo "$date_part" | cut -d'-' -f2)
            local yyyy=$(echo "$date_part" | cut -d'-' -f3)
            
            # Convert month to number
            case $mon in
                Jan) mm="01" ;;
                Feb) mm="02" ;;
                Mar) mm="03" ;;
                Apr) mm="04" ;;
                May) mm="05" ;;
                Jun) mm="06" ;;
                Jul) mm="07" ;;
                Aug) mm="08" ;;
                Sep) mm="09" ;;
                Oct) mm="10" ;;
                Nov) mm="11" ;;
                Dec) mm="12" ;;
                *) mm="01" ;;
            esac
            
            local date_ymd="${yyyy}${mm}${dd}"
            local new_filename="${date_ymd}-${iso_file}"
            local iso_url="${PBS_DOWNLOAD_DIR}${iso_file}"
            
            iso_entries+=("$iso_url|$new_filename|$date_part")
        fi
    done < <(echo "$html_content")
    
    echo "${iso_entries[@]}"
}

function select_iso() {
    local menu_items=()
    local iso_entries=()
    
    # Try to fetch available ISOs
    msg_info "Fetching available PBS ISOs from $PBS_DOWNLOAD_DIR"
    
    local html_content
    if html_content=$(curl -s --connect-timeout 10 "$PBS_DOWNLOAD_DIR" 2>/dev/null); then
        IFS=' ' read -ra iso_entries <<< "$(parse_iso_listing "$html_content")"
        
        if [ ${#iso_entries[@]} -gt 0 ]; then
            msg_ok "Found ${#iso_entries[@]} PBS ISO(s)"
            
            # Sort by date (newest first)
            IFS=$'\n' sorted_entries=($(printf '%s\n' "${iso_entries[@]}" | sort -t'|' -k1 -r))
            
            for entry in "${sorted_entries[@]}"; do
                IFS='|' read -r url filename date_str <<< "$entry"
                menu_items+=("$url" "$filename - Updated: $date_str")
            done
        else
            msg_warn "No PBS ISOs found in directory listing"
        fi
    else
        msg_warn "Could not fetch ISO listing from Proxmox repository"
    fi
    
    # Always add fallback
    menu_items+=("$FALLBACK_URL" "$FALLBACK_FILENAME - Updated: ${FALLBACK_DATE} (Fallback)")
    
    # Select download or local
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "ISO SELECTION" \
        --yesno "Would you like to download a PBS ISO from the internet?\n\nChoose 'No' to select a locally available ISO." 12 70; then
        
        # Download ISO
        local chosen_url
        chosen_url=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "Available PBS ISOs" \
            --menu "Select an ISO to download:\n\nUse arrow keys to navigate and Enter to select." \
            20 100 8 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
        
        download_iso "$chosen_url"
    else
        # Select local ISO
        select_local_iso
    fi
}

function download_iso() {
    local url="$1"
    local basename=""
    
    # Determine basename
    if [ "$url" = "$FALLBACK_URL" ]; then
        basename="$FALLBACK_FILENAME"
    else
        # Find matching entry
        for entry in "${iso_entries[@]}"; do
            IFS='|' read -r entry_url filename date_str <<< "$entry"
            if [ "$entry_url" = "$url" ]; then
                basename="$filename"
                break
            fi
        done
        
        if [ -z "$basename" ]; then
            basename="$FALLBACK_FILENAME"
        fi
    fi
    
    ISO_BASENAME="$basename"
    local iso_path="/var/lib/vz/template/iso/$basename"
    
    # Check if already exists
    if [ -f "$iso_path" ]; then
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "ISO EXISTS" \
            --yesno "ISO file '$basename' already exists.\n\nUse existing file?" 10 60; then
            msg_ok "Using existing ISO: $basename"
            ISO_PATH="$iso_path"
            return
        else
            msg_info "Removing existing ISO"
            rm -f "$iso_path"
        fi
    fi
    
    # Download ISO
    msg_info "Downloading PBS ISO (this may take several minutes)"
    
    if wget --progress=bar:force:noscroll "$url" -O "$iso_path" 2>&1 | \
        stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
        whiptail --gauge "Downloading PBS ISO..." 8 50 0; then
        msg_ok "Downloaded $basename"
        ISO_PATH="$iso_path"
    else
        msg_error "Failed to download PBS ISO"
        rm -f "$iso_path"
        
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "DOWNLOAD FAILED" \
            --yesno "Download failed. Select a local ISO instead?" 10 60; then
            select_local_iso
        else
            exit 1
        fi
    fi
}

function select_local_iso() {
    local iso_list=()
    local iso_dir="/var/lib/vz/template/iso"
    
    # Find all ISO files
    while IFS= read -r iso_file; do
        local basename=$(basename "$iso_file")
        local size=$(du -h "$iso_file" | cut -f1)
        iso_list+=("$basename" "Size: $size")
    done < <(find "$iso_dir" -type f -name "*.iso" | sort)
    
    if [ ${#iso_list[@]} -eq 0 ]; then
        msg_error "No ISO files found in $iso_dir"
        exit 1
    fi
    
    local chosen_iso
    chosen_iso=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "Local ISO Files" \
        --menu "Select a local ISO file:" 20 80 10 \
        "${iso_list[@]}" 3>&1 1>&2 2>&3) || exit_script
    
    if [ -z "$chosen_iso" ]; then
        msg_error "No ISO selected"
        exit 1
    fi
    
    ISO_PATH="$iso_dir/$chosen_iso"
    ISO_BASENAME="$chosen_iso"
    msg_ok "Using local ISO: $chosen_iso"
}

###############################################
#           STORAGE SELECTION                 #
###############################################

function select_storage() {
    local storage_menu=()
    local msg_max_length=0
    
    while read -r line; do
        local tag=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{printf "%-10s", $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')
        local total=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $5)}')
        local item="Type: $type | Free: $free / Total: $total"
        
        if [[ $((${#item} + 2)) -gt ${msg_max_length} ]]; then
            msg_max_length=$((${#item} + 2))
        fi
        
        storage_menu+=("$tag" "$item")
    done < <(pvesm status -content images | awk 'NR>1')
    
    if [[ ${#storage_menu[@]} -eq 0 ]]; then
        msg_error "No valid storage locations found"
        exit 1
    fi
    
    # Auto-select if only one storage
    if [[ ${#storage_menu[@]} -eq 2 ]]; then
        STORAGE="${storage_menu[0]}"
        msg_ok "Using storage: $STORAGE"
        return
    fi
    
    STORAGE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "Storage Selection" \
        --menu "Select storage location for PBS VM:\n\nUse arrow keys to navigate and Enter to select." \
        20 $((msg_max_length + 30)) 10 \
        "${storage_menu[@]}" 3>&1 1>&2 2>&3) || exit_script
    
    msg_ok "Using storage: $STORAGE"
}

###############################################
#              VM CREATION                    #
###############################################

function create_vm() {
    msg_info "Creating PBS VM (ID: $VMID)"
    
    # Build network options
    local network_opts="virtio,bridge=$BRG,macaddr=$MAC"
    if [[ -n "$VLAN" ]]; then
        network_opts="$network_opts,tag=$VLAN"
    fi
    if [[ -n "$MTU" && "$MTU" != "$DEFAULT_MTU" ]]; then
        network_opts="$network_opts,mtu=$MTU"
    fi
    
    # Create VM with base configuration
    local create_cmd="qm create $VMID"
    create_cmd="$create_cmd -agent $([[ $QEMU_AGENT == "yes" ]] && echo "enabled=1" || echo "enabled=0")"
    create_cmd="$create_cmd -tablet 0"
    create_cmd="$create_cmd -localtime 1"
    create_cmd="$create_cmd -bios ovmf"
    create_cmd="$create_cmd -machine $MACHINE"
    create_cmd="$create_cmd -cpu $CPU_TYPE"
    create_cmd="$create_cmd -cores $CORE_COUNT"
    create_cmd="$create_cmd -memory $RAM_SIZE"
    create_cmd="$create_cmd -balloon $([[ $BALLOON == "yes" ]] && echo "$RAM_SIZE" || echo "0")"
    create_cmd="$create_cmd -name $HN"
    create_cmd="$create_cmd -tags $VM_TAG"
    create_cmd="$create_cmd -net0 $network_opts"
    create_cmd="$create_cmd -onboot 1"
    create_cmd="$create_cmd -ostype l26"
    create_cmd="$create_cmd -scsihw virtio-scsi-pci"
    
    if [[ $PROTECTION == "yes" ]]; then
        create_cmd="$create_cmd -protection 1"
    fi
    
    # Execute creation
    if ! eval "$create_cmd"; then
        msg_error "Failed to create VM"
        exit 1
    fi
    
    # Add serial console if requested
    if [[ $SERIAL_CONSOLE == "yes" ]]; then
        qm set "$VMID" -serial0 socket
    fi
    
    msg_ok "VM shell created successfully"
}

function attach_disks() {
    msg_info "Creating and attaching disks"
    
    # Create EFI disk
    msg_info "Creating EFI disk (${EFI_DISK_SIZE})"
    if ! qm set "$VMID" -efidisk0 "${STORAGE}:0,size=${EFI_DISK_SIZE},efitype=4m"; then
        msg_error "Failed to create EFI disk"
        exit 1
    fi
    
    # Allocate main disk
    msg_info "Allocating main disk (${DISK_SIZE})"
    local disk_name="vm-${VMID}-disk-1"
    if ! pvesm alloc "$STORAGE" "$VMID" "$disk_name" "$DISK_SIZE"; then
        msg_error "Failed to allocate disk space"
        exit 1
    fi
    
    # Attach main disk with retries
    local retry_count=5
    local retry_delay=3
    local disk_opts="${STORAGE}:${disk_name}"
    
    if [[ -n "$DISK_CACHE" && "$DISK_CACHE" != "none" ]]; then
        disk_opts="${disk_opts},cache=${DISK_CACHE}"
    fi
    
    for ((i=1; i<=retry_count; i++)); do
        if qm set "$VMID" -scsi0 "$disk_opts"; then
            msg_ok "Main disk attached successfully"
            break
        else
            msg_warn "Attempt $i/$retry_count: Failed to attach disk"
            if [[ $i -lt $retry_count ]]; then
                sleep $retry_delay
            else
                msg_error "Failed to attach main disk after $retry_count attempts"
                exit 1
            fi
        fi
    done
    
    # Attach ISO
    msg_info "Attaching installation ISO"
    if ! qm set "$VMID" -ide2 "local:iso/$ISO_BASENAME,media=cdrom"; then
        msg_error "Failed to attach ISO"
        exit 1
    fi
    
    # Set boot order
    if ! qm set "$VMID" -boot order=ide2 -bootdisk scsi0; then
        msg_error "Failed to set boot order"
        exit 1
    fi
    
    msg_ok "All disks attached successfully"
}

function set_vm_description() {
    local creation_date=$(date +"%Y-%m-%d %H:%M:%S")
    local description="<div align='center'>
<h2>Proxmox Backup Server VM</h2>

<p><strong>Created:</strong> $creation_date</p>
<p><strong>VM ID:</strong> $VMID</p>
<p><strong>ISO Used:</strong> $ISO_BASENAME</p>

<hr>

<h3>Configuration</h3>
<table style='text-align: left;'>
<tr><td><strong>CPU:</strong></td><td>$CORE_COUNT cores ($CPU_TYPE)</td></tr>
<tr><td><strong>RAM:</strong></td><td>$RAM_SIZE MiB</td></tr>
<tr><td><strong>Disk:</strong></td><td>$DISK_SIZE</td></tr>
<tr><td><strong>Network:</strong></td><td>Bridge: $BRG"
    
    if [[ -n "$VLAN" ]]; then
        description="$description, VLAN: $VLAN"
    fi
    
    description="$description</td></tr>
</table>

<hr>

<p><a href='https://www.proxmox.com/en/proxmox-backup-server' target='_blank' rel='noopener noreferrer'>
<img src='https://www.proxmox.com/images/proxmox/Proxmox_logo_standard_hex_400px.png' alt='Proxmox Logo' style='width: 200px;'/>
</a></p>

<p><strong>Default Credentials:</strong><br>
Username: <code>root@pam</code><br>
Password: Set during installation</p>
</div>"
    
    qm set "$VMID" -description "$description"
}

###############################################
#        POST-INSTALLATION HELPERS            #
###############################################

function show_post_install_info() {
    whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "POST-INSTALLATION STEPS" \
        --msgbox "PBS Installation Steps:

1. Start the VM and boot from ISO
2. Select 'Install Proxmox Backup Server'
3. Accept the license agreement
4. Select target disk (usually /dev/sda)
5. Configure timezone and password
6. Configure network settings
7. Complete installation and reboot

After installation:
- Access PBS at https://${BRG_IP}:8007
- Login with root@pam and your password
- Configure datastore and backup jobs

Press Enter to continue..." 20 70
}

function configure_post_install() {
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "POST-INSTALLATION" \
        --yesno "Would you like to:

1. Remove the installation ISO
2. Set proper boot order
3. Configure automatic startup

Proceed with post-installation configuration?" 12 60; then
        
        msg_info "Stopping VM for configuration"
        qm stop "$VMID" || true
        
        # Wait for VM to stop
        local timeout=30
        while [[ $timeout -gt 0 ]] && qm status "$VMID" | grep -q "running"; do
            sleep 1
            ((timeout--))
        done
        
        msg_info "Removing installation media"
        qm set "$VMID" -delete ide2
        
        msg_info "Setting boot order to main disk"
        qm set "$VMID" -boot order=scsi0
        
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "AUTO-START" \
            --yesno "Enable automatic VM startup on host boot?" 8 60; then
            qm set "$VMID" -onboot 1 -startup "order=1,up=30"
            msg_ok "Automatic startup configured"
        fi
        
        msg_ok "Post-installation configuration complete"
        
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "START VM" \
            --yesno "Start the PBS VM now?" 8 60; then
            msg_info "Starting PBS VM"
            qm start "$VMID"
            msg_ok "PBS VM started"
        fi
    fi
}

###############################################
#              MAIN EXECUTION                 #
###############################################

# Show header
header_info
echo
read -rsp "Press Enter to continue..." -n1 key
echo

# Initial setup message
msg_info "Initializing Proxmox Backup Server VM creation script"

# Run all checks
check_root
check_dependencies
arch_check
pve_check
ssh_check

# Confirm proceeding
if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
    --title "Proxmox Backup Server VM" \
    --yesno "This script will create a new Proxmox Backup Server VM.

Requirements:
- Proxmox VE 8.1 or later
- At least 2GB RAM available
- At least 30GB disk space
- Network bridge configured

Proceed with VM creation?" 15 70; then
    header_info
    echo -e "User cancelled operation.\n"
    exit 1
fi

# Configure VM settings
start_script

# Verify bridge exists
verify_bridge_exists "$BRG"

# Display configuration summary
whiptail --backtitle "Proxmox VE PBS Install Script" \
    --title "CONFIGURATION SUMMARY" \
    --msgbox "VM Configuration:

VM ID: $VMID
Hostname: $HN
CPU: $CORE_COUNT cores ($CPU_TYPE)
RAM: $RAM_SIZE MiB
Disk: $DISK_SIZE
Network: Bridge $BRG$([ -n "$VLAN" ] && echo ", VLAN $VLAN")
Machine: $MACHINE
Tags: $VM_TAG

Press Enter to proceed..." 18 60

# Create temporary directory
TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# Select and prepare ISO
select_iso

# Select storage
select_storage

# Create VM
create_vm

# Attach disks and ISO
attach_disks

# Set VM description
set_vm_description

msg_ok "PBS VM created successfully (ID: $VMID, Name: $HN)"

# Handle VM startup and installation
if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starting PBS VM"
    qm start "$VMID"
    msg_ok "PBS VM started"
    
    # Show post-installation information
    show_post_install_info
    
    # Wait for installation
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "INSTALLATION IN PROGRESS" \
        --yesno "Is the PBS installation complete?" 8 60; then
        configure_post_install
    fi
else
    msg_info "VM created but not started"
    msg_info "Start manually with: qm start $VMID"
fi

# Cleanup
popd >/dev/null
cleanup

# Final summary
echo
msg_ok "Proxmox Backup Server VM setup completed!"
echo
echo -e "${INFO} VM Information:"
echo -e "  ID: ${GN}$VMID${CL}"
echo -e "  Name: ${GN}$HN${CL}"
echo -e "  Storage: ${GN}$STORAGE${CL}"
echo

if [[ $SERIAL_CONSOLE == "yes" ]]; then
    echo -e "${INFO} Access Options:"
    echo -e "  Console: ${GN}qm terminal $VMID${CL}"
    echo -e "  Serial: ${GN}qm terminal $VMID -iface serial0${CL}"
else
    echo -e "${INFO} Console Access: ${GN}qm terminal $VMID${CL}"
fi

echo
echo -e "${INFO} Default PBS Credentials:"
echo -e "  Username: ${GN}root@pam${CL}"
echo -e "  Password: ${GN}(set during installation)${CL}"
echo
echo -e "${INFO} After installation, access PBS at:"
echo -e "  ${GN}https://<PBS-IP>:8007${CL}"
echo

exit 0
