#!/usr/bin/env bash
# Purpose: Automate the creation of a Talos VM in Proxmox with Image Factory integration
# Features:
# - Talos Image Factory integration for custom system extensions
# - Dynamic version selection from official releases
# - System extension selection (QEMU Guest Agent, Intel i915, etc.)
# - Multiple image format support (ISO, raw, qcow2)
# - Advanced VM configuration options
# - Post-installation helpers

set -euo pipefail

###############################################
#               CONFIGURATION                 #
###############################################

# Image Factory Configuration
IMAGE_FACTORY_URL="https://factory.talos.dev"
PXE_FACTORY_URL="https://pxe.factory.talos.dev"
TALOS_GITHUB_API="https://api.github.com/repos/siderolabs/talos/releases"

# Default schematic ID (no customizations)
DEFAULT_SCHEMATIC="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"

# VM Defaults
STARTING_VM_ID=111
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MTU="1500"
DEFAULT_DISK_SIZE="80G"
DEFAULT_RAM_SIZE="2048"
DEFAULT_CPU_CORES="2"

# Terminal color codes
CL="\033[m"               # Clear
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
#              GLOBAL VARIABLES               #
###############################################

TEMP_DIR=""
VMID=""
MACHINE=""
CPU_TYPE=""
BRG=""
HN=""
ISO_FILE=""
ISO_PATH=""
STORAGE=""
EFI_DISK_SIZE=""
VM_TAG=""
MTU=""
VLAN=""
DISK_SIZE=""
RAM_SIZE=""
CORE_COUNT=""
DISK_CACHE=""
START_VM=""
FORMAT=",efitype=4m"
SCHEMATIC_ID=""
TALOS_VERSION=""
SELECTED_EXTENSIONS=()
IMAGE_FORMAT="iso"
SERIAL_CONSOLE=""
QEMU_AGENT=""
BALLOON=""
MAC=""
INSTALLER_IMAGE=""

###############################################
#                 FUNCTIONS                   #
###############################################

function header_info {
    clear
    cat <<"EOF"
                                                 
888888888888         88                          
     88              88                          
     88              88                          
     88  ,adPPYYba,  88   ,adPPYba,   ,adPPYba,  
     88  ""     `Y8  88  a8"     "8a  I8[    ""  
     88  ,adPPPPP88  88  8b       d8   `"Y8ba,   
     88  88,    ,88  88  "8a,   ,a8"  aa    ]8I  
     88  `"8bbdP"Y8  88   `"YbbdP"'   `"YbbdP"'
     
          T A L O S   L I N U X   V M                                                   
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

# Progress indicator
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

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
    cleanup_vmid
    exit $exit_code
}

function cleanup_vmid() {
    if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        msg_info "Cleaning up VM $VMID"
        qm stop "$VMID" &>/dev/null || true
        sleep 2
        qm destroy "$VMID" &>/dev/null || true
    fi
}

function cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

###############################################
#           DEPENDENCY CHECKING               #
###############################################

function check_dependencies() {
    local deps=(whiptail pvesh pvesm qm wget curl openssl jq numfmt)
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

function arch_check() {
    local arch=$(dpkg --print-architecture)
    if [[ "$arch" != "amd64" ]]; then
        msg_error "This script requires amd64 architecture (current: $arch)"
        msg_warn "Talos Linux is not supported on ARM architectures for this deployment"
        exit 1
    fi
}

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" ]]; then
        if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's recommended to use the Proxmox shell instead of SSH.\n\nSSH can cause issues with interactive elements.\n\nContinue anyway?" 12 62; then
            clear
            exit 1
        fi
    fi
}

###############################################
#         TALOS IMAGE FACTORY API             #
###############################################

function get_talos_versions() {
    msg_info "Fetching available Talos versions..."
    
    local versions_json
    if ! versions_json=$(curl -s --connect-timeout 10 "${IMAGE_FACTORY_URL}/versions" 2>/dev/null); then
        msg_error "Failed to fetch Talos versions from Image Factory"
        # Fallback to GitHub API
        msg_info "Trying GitHub API as fallback..."
        if ! versions_json=$(curl -s --connect-timeout 10 "${TALOS_GITHUB_API}/latest" | jq -r '.tag_name' 2>/dev/null); then
            msg_error "Failed to fetch versions from both sources"
            return 1
        fi
        echo "[\"$versions_json\"]"
        return 0
    fi
    
    echo "$versions_json"
}

function get_system_extensions() {
    local version="$1"
    msg_info "Fetching available system extensions for Talos $version..."
    
    local extensions_json
    if ! extensions_json=$(curl -s --connect-timeout 10 "${IMAGE_FACTORY_URL}/version/${version}/extensions/official" 2>/dev/null); then
        msg_warn "Failed to fetch system extensions"
        return 1
    fi
    
    echo "$extensions_json"
}

function create_schematic() {
    local extensions=("$@")
    
    if [ ${#extensions[@]} -eq 0 ]; then
        # No extensions selected, use default schematic
        SCHEMATIC_ID="$DEFAULT_SCHEMATIC"
        msg_ok "Using default schematic (no customizations)"
        return 0
    fi
    
    msg_info "Creating custom schematic with selected extensions..."
    
    # Build the schematic YAML
    local schematic_yaml="customization:
  systemExtensions:
    officialExtensions:"
    
    for ext in "${extensions[@]}"; do
        schematic_yaml="$schematic_yaml
      - $ext"
    done
    
    # POST to create schematic
    local response
    if ! response=$(curl -s -X POST \
        -H "Content-Type: text/plain" \
        -d "$schematic_yaml" \
        "${IMAGE_FACTORY_URL}/schematics" 2>/dev/null); then
        msg_error "Failed to create schematic"
        return 1
    fi
    
    # Extract schematic ID
    SCHEMATIC_ID=$(echo "$response" | jq -r '.id' 2>/dev/null)
    
    if [ -z "$SCHEMATIC_ID" ] || [ "$SCHEMATIC_ID" = "null" ]; then
        msg_error "Failed to parse schematic ID from response"
        return 1
    fi
    
    msg_ok "Created schematic ID: ${SCHEMATIC_ID:0:16}..."
    return 0
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
        
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
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
    HN="TalosVM${VMID}"
    CPU_TYPE="host"
    CORE_COUNT="$DEFAULT_CPU_CORES"
    RAM_SIZE="$DEFAULT_RAM_SIZE"
    DISK_SIZE="$DEFAULT_DISK_SIZE"
    BRG="$DEFAULT_BRIDGE"
    MAC=$(generate_mac)
    VLAN=""
    MTU="$DEFAULT_MTU"
    START_VM="yes"
    VM_TAG="kubernetes,talos"
    EFI_DISK_SIZE="512M"
    SERIAL_CONSOLE="yes"
    QEMU_AGENT="yes"
    BALLOON="yes"
    IMAGE_FORMAT="iso"
    
    msg_ok "Default settings applied"
}

function advanced_settings() {
    check_vmid
    
    # VM ID
    VMID=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Virtual Machine ID (Default: $NEXTID)" 8 60 "$NEXTID" \
        --title "VIRTUAL MACHINE ID" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Validate VM ID
    if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
        msg_error "VM ID must be a number"
        exit 1
    fi
    
    # Hostname
    HN=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Hostname (Default: TalosVM$VMID)" 8 60 "TalosVM${VMID}" \
        --title "HOSTNAME" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Machine Type
    MACHINE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "MACHINE TYPE" --radiolist "Select machine type:" 10 60 2 \
        "q35" "Q35: Modern with PCIe support (recommended)" ON \
        "i440fx" "i440fx: Legacy compatibility" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # Disk Cache
    DISK_CACHE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "DISK CACHE" --radiolist "Select disk cache mode:" 12 60 4 \
        "none" "None (recommended for integrity)" ON \
        "writeback" "Writeback (better performance)" OFF \
        "writethrough" "Writethrough (balanced)" OFF \
        "directsync" "Direct sync (safest)" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # CPU Type
    CPU_TYPE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "CPU MODEL" --radiolist "Select CPU model:" 12 60 4 \
        "host" "Host (best performance)" ON \
        "kvm64" "KVM64 (compatibility)" OFF \
        "qemu64" "QEMU64 (maximum compatibility)" OFF \
        "max" "Maximum features" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    # CPU Cores
    CORE_COUNT=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Number of CPU cores (Default: 2)" 8 60 "2" \
        --title "CPU CORES" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # RAM Size
    RAM_SIZE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "RAM size in MiB (Default: 2048)" 8 60 "2048" \
        --title "RAM SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Disk Size
    DISK_SIZE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Disk size (Default: 80G)" 8 60 "80G" \
        --title "DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Network Bridge
    BRG=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Network Bridge (Default: $DEFAULT_BRIDGE)" 8 60 "$DEFAULT_BRIDGE" \
        --title "NETWORK BRIDGE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # MAC Address
    MAC=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "MAC Address (Auto-generated)" 8 60 "$(generate_mac)" \
        --title "MAC ADDRESS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # VLAN Tag
    VLAN=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "VLAN Tag (Leave empty for none)" 8 60 "" \
        --title "VLAN TAG" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # MTU Size
    MTU=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "Interface MTU Size (Default: $DEFAULT_MTU)" 8 60 "$DEFAULT_MTU" \
        --title "MTU SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # VM Tags
    VM_TAG=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "VM Tags (comma-separated)" 8 60 "kubernetes,talos" \
        --title "VM TAGS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # EFI Disk Size
    EFI_DISK_SIZE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --inputbox "EFI Disk Size (Default: 512M)" 8 60 "512M" \
        --title "EFI DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    
    # Additional Options
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "SERIAL CONSOLE" --yesno "Enable serial console?" 8 60; then
        SERIAL_CONSOLE="yes"
    else
        SERIAL_CONSOLE="no"
    fi
    
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "QEMU AGENT" --yesno "Enable QEMU Guest Agent?\n\n(Requires qemu-guest-agent extension)" 10 60; then
        QEMU_AGENT="yes"
    else
        QEMU_AGENT="no"
    fi
    
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "MEMORY BALLOONING" --yesno "Enable memory ballooning?" 8 60; then
        BALLOON="yes"
    else
        BALLOON="no"
    fi
    
    # Image Format Selection
    IMAGE_FORMAT=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "IMAGE FORMAT" --radiolist "Select image format:" 12 60 3 \
        "iso" "ISO (traditional installation)" ON \
        "raw" "Raw disk image" OFF \
        "qcow2" "QCOW2 disk image" OFF \
        3>&1 1>&2 2>&3) || exit_script
    
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "START VIRTUAL MACHINE" --yesno "Start VM when completed?" 10 60; then
        START_VM="yes"
    else
        START_VM="no"
    fi
    
    msg_ok "Advanced settings configured"
}

function start_script() {
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "SETTINGS" \
        --yesno "Use Default Settings?" --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

###############################################
#        TALOS VERSION SELECTION              #
###############################################

function select_talos_version() {
    local versions_json
    versions_json=$(get_talos_versions)
    
    if [ -z "$versions_json" ] || [ "$versions_json" = "[]" ]; then
        # Fallback to latest from GitHub
        msg_warn "Could not fetch versions, using latest"
        TALOS_VERSION="v1.10.2"
        return
    fi
    
    # Parse versions into menu items
    local menu_items=()
    while IFS= read -r version; do
        # Clean up version string
        version=$(echo "$version" | tr -d '"' | tr -d ' ')
        if [ -n "$version" ]; then
            menu_items+=("$version" "Talos Linux $version")
        fi
    done < <(echo "$versions_json" | jq -r '.[]' 2>/dev/null)
    
    if [ ${#menu_items[@]} -eq 0 ]; then
        msg_warn "No versions found, using latest"
        TALOS_VERSION="v1.10.2"
        return
    fi
    
    # Show version selection menu
    TALOS_VERSION=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "TALOS VERSION" \
        --menu "Select Talos Linux version:" 20 60 10 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    
    msg_ok "Selected Talos version: $TALOS_VERSION"
}

###############################################
#        SYSTEM EXTENSION SELECTION           #
###############################################

function select_system_extensions() {
    # Auto-add qemu-guest-agent if QEMU Agent is enabled
    if [ "$QEMU_AGENT" = "yes" ]; then
        SELECTED_EXTENSIONS+=("siderolabs/qemu-guest-agent")
        msg_info "Auto-selected qemu-guest-agent extension (QEMU Agent enabled)"
    fi
    
    # Get available extensions
    local extensions_json
    extensions_json=$(get_system_extensions "$TALOS_VERSION")
    
    if [ -z "$extensions_json" ] || [ "$extensions_json" = "[]" ]; then
        msg_warn "Could not fetch available extensions"
        
        # Offer common extensions manually
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "SYSTEM EXTENSIONS" \
            --yesno "Would you like to add Intel i915 graphics driver?" 8 60; then
            SELECTED_EXTENSIONS+=("siderolabs/i915")
        fi
        
        return
    fi
    
    # Parse extensions into checklist items
    local checklist_items=()
    while IFS= read -r line; do
        local name=$(echo "$line" | jq -r '.name' 2>/dev/null)
        local ref=$(echo "$line" | jq -r '.ref' 2>/dev/null)
        
        if [ -n "$name" ] && [ "$name" != "null" ]; then
            # Check if already selected
            local selected="OFF"
            for ext in "${SELECTED_EXTENSIONS[@]}"; do
                if [ "$ext" = "$name" ]; then
                    selected="ON"
                    break
                fi
            done
            
            # Add description based on extension name
            local desc=""
            case "$name" in
                *qemu-guest-agent*) desc="QEMU Guest Agent for VM integration" ;;
                *i915*) desc="Intel graphics driver" ;;
                *amd-ucode*) desc="AMD CPU microcode" ;;
                *intel-ucode*) desc="Intel CPU microcode" ;;
                *gvisor*) desc="gVisor container runtime" ;;
                *nvidia*) desc="NVIDIA GPU driver" ;;
                *gasket-driver*) desc="Google Gasket driver" ;;
                **)  desc="${ref##*/}" ;;
            esac
            
            checklist_items+=("$name" "$desc" "$selected")
        fi
    done < <(echo "$extensions_json" | jq -c '.[]' 2>/dev/null)
    
    if [ ${#checklist_items[@]} -eq 0 ]; then
        msg_warn "No extensions available for this version"
        return
    fi
    
    # Show extension selection checklist
    local selected_list
    selected_list=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "SYSTEM EXTENSIONS" \
        --checklist "Select system extensions to include:\n(Space to select, Enter to confirm)" \
        20 80 10 \
        "${checklist_items[@]}" 3>&1 1>&2 2>&3) || return
    
    # Parse selected extensions
    SELECTED_EXTENSIONS=()
    while IFS= read -r ext; do
        ext=$(echo "$ext" | tr -d '"')
        if [ -n "$ext" ]; then
            SELECTED_EXTENSIONS+=("$ext")
        fi
    done < <(echo "$selected_list")
    
    if [ ${#SELECTED_EXTENSIONS[@]} -gt 0 ]; then
        msg_ok "Selected ${#SELECTED_EXTENSIONS[@]} extension(s)"
    fi
}

###############################################
#           ISO/IMAGE HANDLING                #
###############################################

function download_talos_image() {
    local image_type="$1"
    local schematic="${2:-$DEFAULT_SCHEMATIC}"
    local version="${3:-$TALOS_VERSION}"
    
    # Construct the download URL based on image type
    local download_url=""
    local filename=""
    
    case "$image_type" in
        "iso")
            download_url="${IMAGE_FACTORY_URL}/image/${schematic}/${version}/metal-amd64.iso"
            filename="talos-${version}-${schematic:0:16}-metal-amd64.iso"
            ;;
        "raw")
            download_url="${IMAGE_FACTORY_URL}/image/${schematic}/${version}/metal-amd64.raw.zst"
            filename="talos-${version}-${schematic:0:16}-metal-amd64.raw.zst"
            ;;
        "qcow2")
            download_url="${IMAGE_FACTORY_URL}/image/${schematic}/${version}/metal-amd64.qcow2"
            filename="talos-${version}-${schematic:0:16}-metal-amd64.qcow2"
            ;;
        *)
            msg_error "Unknown image type: $image_type"
            return 1
            ;;
    esac
    
    # Set global variables
    ISO_FILE="$filename"
    local target_path
    
    if [ "$image_type" = "iso" ]; then
        target_path="/var/lib/vz/template/iso/$filename"
        ISO_PATH="$target_path"
    else
        # For disk images, download to temp first
        target_path="${TEMP_DIR}/$filename"
    fi
    
    # Check if already exists (for ISOs)
    if [ "$image_type" = "iso" ] && [ -f "$target_path" ]; then
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "IMAGE EXISTS" \
            --yesno "Image '$filename' already exists.\n\nUse existing file?" 10 60; then
            msg_ok "Using existing image"
            return 0
        else
            msg_info "Removing existing image"
            rm -f "$target_path"
        fi
    fi
    
    # Download the image
    msg_info "Downloading Talos $image_type image (this may take several minutes)"
    
    if wget --progress=bar:force:noscroll "$download_url" -O "$target_path" 2>&1 | \
        stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
        whiptail --gauge "Downloading Talos $image_type..." 8 50 0; then
        
        # Handle compressed raw images
        if [[ "$filename" == *.zst ]]; then
            msg_info "Decompressing raw image..."
            if ! zstd -d "$target_path" -o "${target_path%.zst}"; then
                msg_error "Failed to decompress image"
                return 1
            fi
            rm -f "$target_path"
            ISO_FILE="${filename%.zst}"
            target_path="${target_path%.zst}"
        fi
        
        msg_ok "Downloaded Talos $image_type"
        return 0
    else
        msg_error "Failed to download Talos $image_type"
        rm -f "$target_path"
        return 1
    fi
}

function select_local_image() {
    local image_list=()
    local iso_dir="/var/lib/vz/template/iso"
    
    # Find all potential Talos images
    while IFS= read -r image_file; do
        local basename=$(basename "$image_file")
        local size=$(du -h "$image_file" | cut -f1)
        image_list+=("$basename" "Size: $size")
    done < <(find "$iso_dir" -type f \( -name "*talos*.iso" -o -name "*.iso" \) | sort)
    
    if [ ${#image_list[@]} -eq 0 ]; then
        msg_error "No ISO files found in $iso_dir"
        return 1
    fi
    
    local chosen_image
    chosen_image=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "Local Images" \
        --menu "Select a local image file:" 20 80 10 \
        "${image_list[@]}" 3>&1 1>&2 2>&3) || return 1
    
    if [ -z "$chosen_image" ]; then
        msg_error "No image selected"
        return 1
    fi
    
    ISO_PATH="$iso_dir/$chosen_image"
    ISO_FILE="$chosen_image"
    msg_ok "Using local image: $chosen_image"
    return 0
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
        
        storage_menu+=("$tag" "$item" "OFF")
    done < <(pvesm status -content images | awk 'NR>1')
    
    if [[ ${#storage_menu[@]} -eq 0 ]]; then
        msg_error "No valid storage locations found"
        exit 1
    fi
    
    # Auto-select if only one storage
    if [[ ${#storage_menu[@]} -eq 3 ]]; then
        STORAGE="${storage_menu[0]}"
        msg_ok "Using storage: $STORAGE"
        return
    fi
    
    STORAGE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "Storage Selection" \
        --radiolist "Select storage location for Talos VM:\n\nUse Space to select and Enter to confirm." \
        20 $((msg_max_length + 30)) 10 \
        "${storage_menu[@]}" 3>&1 1>&2 2>&3) || exit_script
    
    if [[ -z "$STORAGE" ]]; then
        STORAGE="${storage_menu[0]}"
    fi
    
    msg_ok "Using storage: $STORAGE"
}

###############################################
#              VM CREATION                    #
###############################################

function create_vm() {
    msg_info "Creating Talos VM (ID: $VMID)"
    
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
    
    # Handle different image formats
    case "$IMAGE_FORMAT" in
        "iso")
            # Allocate main disk
            msg_info "Allocating main disk (${DISK_SIZE})"
            local disk_name="vm-${VMID}-disk-1"
            if ! pvesm alloc "$STORAGE" "$VMID" "$disk_name" "$DISK_SIZE"; then
                msg_error "Failed to allocate disk space"
                exit 1
            fi
            
            # Attach main disk
            local disk_opts="${STORAGE}:${disk_name}"
            if [[ -n "$DISK_CACHE" && "$DISK_CACHE" != "none" ]]; then
                disk_opts="${disk_opts},cache=${DISK_CACHE}"
            fi
            
            # Retry logic for disk attachment
            local retry_count=5
            local retry_delay=3
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
            if ! qm set "$VMID" -ide2 "local:iso/$ISO_FILE,media=cdrom"; then
                msg_error "Failed to attach ISO"
                exit 1
            fi
            
            # Set boot order
            if ! qm set "$VMID" -boot order=ide2 -bootdisk scsi0; then
                msg_error "Failed to set boot order"
                exit 1
            fi
            ;;
            
        "raw"|"qcow2")
            # Import disk image
            msg_info "Importing disk image"
            local import_format=""
            if [ "$IMAGE_FORMAT" = "qcow2" ]; then
                import_format="--format qcow2"
            fi
            
            if ! qm importdisk "$VMID" "${TEMP_DIR}/${ISO_FILE}" "$STORAGE" $import_format; then
                msg_error "Failed to import disk image"
                exit 1
            fi
            
            # Attach imported disk
            msg_info "Attaching imported disk"
            local unused_disk=$(qm config "$VMID" | grep -m1 "^unused" | cut -d: -f1)
            if [ -n "$unused_disk" ]; then
                local disk_ref=$(qm config "$VMID" | grep "^$unused_disk:" | cut -d' ' -f2)
                
                local disk_opts="$disk_ref"
                if [[ -n "$DISK_CACHE" && "$DISK_CACHE" != "none" ]]; then
                    disk_opts="${disk_opts},cache=${DISK_CACHE}"
                fi
                
                if ! qm set "$VMID" -scsi0 "$disk_opts"; then
                    msg_error "Failed to attach imported disk"
                    exit 1
                fi
                
                # Set boot order
                if ! qm set "$VMID" -boot order=scsi0; then
                    msg_error "Failed to set boot order"
                    exit 1
                fi
            else
                msg_error "Could not find imported disk"
                exit 1
            fi
            ;;
    esac
    
    msg_ok "All disks attached successfully"
}

function set_vm_description() {
    local creation_date=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Build extension list
    local ext_list=""
    if [ ${#SELECTED_EXTENSIONS[@]} -gt 0 ]; then
        ext_list="<h4>System Extensions:</h4><ul>"
        for ext in "${SELECTED_EXTENSIONS[@]}"; do
            ext_list="$ext_list<li>$ext</li>"
        done
        ext_list="$ext_list</ul>"
    fi
    
    local description="<div align='center'>
<h2>Talos Linux VM</h2>

<p><strong>Created:</strong> $creation_date</p>
<p><strong>VM ID:</strong> $VMID</p>
<p><strong>Version:</strong> $TALOS_VERSION</p>
<p><strong>Schematic ID:</strong> ${SCHEMATIC_ID:0:16}...</p>
<p><strong>Image Format:</strong> $IMAGE_FORMAT</p>

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

$ext_list

<hr>

<p><strong>Installer Image:</strong><br>
<code>$INSTALLER_IMAGE</code></p>

<hr>

<p><a href='https://www.talos.dev/' target='_blank' rel='noopener noreferrer'>
<img src='https://avatars.githubusercontent.com/u/13804887?s=200&v=4' alt='Talos Logo' style='width: 100px;'/>
</a></p>

<p><strong>Documentation:</strong><br>
<a href='https://www.talos.dev/v${TALOS_VERSION#v}/introduction/getting-started/'>Getting Started</a> | 
<a href='https://www.talos.dev/v${TALOS_VERSION#v}/talos-guides/install/virtualized-platforms/proxmox/'>Proxmox Guide</a>
</p>
</div>"
    
    qm set "$VMID" -description "$description"
}

###############################################
#        POST-INSTALLATION HELPERS            #
###############################################

function show_post_install_info() {
    # Set installer image reference
    INSTALLER_IMAGE="factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TALOS_VERSION}"
    
    whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "TALOS CONFIGURATION" \
        --msgbox "Talos Linux Configuration Information:

VM ID: $VMID
Hostname: $HN
Version: $TALOS_VERSION
Schematic: ${SCHEMATIC_ID:0:16}...

System Extensions:
$(for ext in "${SELECTED_EXTENSIONS[@]}"; do echo "- $ext"; done)

To configure this node:
1. Boot the VM and get the IP address
2. Generate machine config with:
   talosctl gen config <cluster-name> <endpoint>
3. Apply configuration with:
   talosctl apply-config -n <node-ip> -f <config>.yaml
4. Use installer image for upgrades:
   $INSTALLER_IMAGE

Press Enter to continue..." 25 80
}

function configure_post_install() {
    if [ "$IMAGE_FORMAT" != "iso" ]; then
        # No post-install for disk images
        return
    fi
    
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "POST-INSTALLATION" \
        --yesno "Would you like to:

1. Remove the installation ISO
2. Set boot order to main disk

Proceed with post-installation cleanup?" 12 60; then
        
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
        
        msg_ok "Post-installation cleanup complete"
        
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "START VM" \
            --yesno "Start the Talos VM now?" 8 60; then
            msg_info "Starting Talos VM"
            qm start "$VMID"
            msg_ok "Talos VM started"
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
msg_info "Initializing Talos Linux VM creation script"

# Run all checks
check_root
check_dependencies
arch_check
pve_check
ssh_check

# Confirm proceeding
if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
    --title "Talos Linux VM" \
    --yesno "This script will create a new Talos Linux VM with:

- Image Factory integration for custom builds
- System extension support (QEMU Agent, Intel drivers, etc.)
- Multiple image format options (ISO, raw, qcow2)
- Advanced VM configuration

Requirements:
- Proxmox VE 8.1 or later
- Internet connection for Image Factory
- At least 2GB RAM and 80GB disk space

Proceed with VM creation?" 18 70; then
    header_info
    echo -e "User cancelled operation.\n"
    exit 1
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# Configure VM settings
start_script

# Select Talos version
select_talos_version

# Select system extensions
select_system_extensions

# Create schematic if extensions selected
if [ ${#SELECTED_EXTENSIONS[@]} -gt 0 ]; then
    if ! create_schematic "${SELECTED_EXTENSIONS[@]}"; then
        msg_error "Failed to create custom schematic"
        exit 1
    fi
else
    SCHEMATIC_ID="$DEFAULT_SCHEMATIC"
fi

# Handle image selection/download
if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
    --title "IMAGE SOURCE" \
    --yesno "Download Talos image from Image Factory?\n\nChoose 'No' to select a local image." 10 60; then
    
    # Download from Image Factory
    if ! download_talos_image "$IMAGE_FORMAT" "$SCHEMATIC_ID" "$TALOS_VERSION"; then
        msg_error "Failed to download image"
        
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "DOWNLOAD FAILED" \
            --yesno "Download failed. Try selecting a local image?" 8 60; then
            if ! select_local_image; then
                exit 1
            fi
        else
            exit 1
        fi
    fi
else
    # Select local image
    if ! select_local_image; then
        exit 1
    fi
fi

# Verify bridge exists
verify_bridge_exists "$BRG"

# Select storage
select_storage

# Display configuration summary
whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
    --title "CONFIGURATION SUMMARY" \
    --msgbox "VM Configuration:

VM ID: $VMID
Hostname: $HN
Version: $TALOS_VERSION
Schematic: ${SCHEMATIC_ID:0:16}...
CPU: $CORE_COUNT cores ($CPU_TYPE)
RAM: $RAM_SIZE MiB
Disk: $DISK_SIZE
Network: Bridge $BRG$([ -n "$VLAN" ] && echo ", VLAN $VLAN")
Machine: $MACHINE
Tags: $VM_TAG
Extensions: ${#SELECTED_EXTENSIONS[@]} selected

Press Enter to create VM..." 20 60

# Create VM
create_vm

# Attach disks and images
attach_disks

# Set VM description
set_vm_description

msg_ok "Talos VM created successfully (ID: $VMID, Name: $HN)"

# Show post-installation information
show_post_install_info

# Handle VM startup
if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starting Talos VM"
    qm start "$VMID"
    msg_ok "Talos VM started"
    
    # Post-installation cleanup for ISO installs
    if [ "$IMAGE_FORMAT" = "iso" ]; then
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "INSTALLATION" \
            --yesno "The VM is now running with the Talos installer.\n\nOnce Talos is installed to disk, select Yes to remove the ISO and set proper boot order." 12 70; then
            configure_post_install
        fi
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
msg_ok "Talos Linux VM setup completed!"
echo
echo -e "${INFO} VM Information:"
echo -e "  ID: ${GN}$VMID${CL}"
echo -e "  Name: ${GN}$HN${CL}"
echo -e "  Version: ${GN}$TALOS_VERSION${CL}"
echo -e "  Storage: ${GN}$STORAGE${CL}"
echo -e "  Schematic: ${GN}${SCHEMATIC_ID:0:16}...${CL}"
echo

if [ ${#SELECTED_EXTENSIONS[@]} -gt 0 ]; then
    echo -e "${INFO} System Extensions:"
    for ext in "${SELECTED_EXTENSIONS[@]}"; do
        echo -e "  - ${GN}$ext${CL}"
    done
    echo
fi

echo -e "${INFO} Next Steps:"
echo -e "  1. Boot the VM and get the node IP"
echo -e "  2. Generate Talos configuration:"
echo -e "     ${BL}talosctl gen config <cluster-name> https://<node-ip>:6443${CL}"
echo -e "  3. Apply configuration:"
echo -e "     ${BL}talosctl apply-config -n <node-ip> -f controlplane.yaml${CL}"
echo -e "  4. Bootstrap cluster (first node only):"
echo -e "     ${BL}talosctl bootstrap -n <node-ip>${CL}"
echo

echo -e "${INFO} Installer Image for Updates:"
echo -e "  ${GN}$INSTALLER_IMAGE${CL}"
echo

if [[ $SERIAL_CONSOLE == "yes" ]]; then
    echo -e "${INFO} Console Access:"
    echo -e "  VGA: ${GN}qm terminal $VMID${CL}"
    echo -e "  Serial: ${GN}qm terminal $VMID -iface serial0${CL}"
fi

echo
exit 0
