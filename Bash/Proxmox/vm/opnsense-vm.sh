#!/usr/bin/env bash
# Purpose: Automate the creation of an OPNsense VM in Proxmox VE
# Dependencies: wget, curl, whiptail, bunzip2, genisoimage, Proxmox CLI tools (qm, pvesm, pvesh)

set -euo pipefail

#################################################################################
# Configuration Settings                                                         #
#################################################################################

# Mirror and fallback settings
MIRROR_BASE_URL="https://mirrors.ocf.berkeley.edu/opnsense/releases/"
FALLBACK_URL="https://pkg.opnsense.org/releases/25.7/OPNsense-25.7-dvd-amd64.iso.bz2"
FALLBACK_RELEASE_DATE="2025-Jul-15"
FALLBACK_VERSION="25.7"

# VM ID range
STARTING_VM_ID=100
NEXTID=$STARTING_VM_ID

# Default interface names
DEFAULT_WAN_BRIDGE="vmbr0"
DEFAULT_LAN_BRIDGE="vmbr1"
DEFAULT_MGMT_BRIDGE="vmbr2"

# Version and installation method
INSTALLATION_METHOD="iso"  # iso or freebsd
# FreeBSD URL will be discovered dynamically; this is a fallback
FREEBSD_URL="https://download.freebsd.org/releases/VM-IMAGES/14.2-RELEASE/amd64/Latest/FreeBSD-14.2-RELEASE-amd64.qcow2.xz"

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
YL="\033[01;33m"          # Yellow
DGN="\033[32m"            # Dark Green
BGN="\033[4;92m"          # Bold Green
BL="\033[36m"             # Blue
HA="\033[1;34m"           # Highlight
CM="${GN}✓${CL}"          # Checkmark
CROSS="${RD}✗${CL}"       # Cross
WARN="${YL}!${CL}"        # Warning
BFR="\\r\\033[K"          # Line clear
HOLD="-"                  # Progress indicator
INFO="${GN}◉${CL}"        # Info indicator
TAB="  "                  # Tab spacing

function msg_info() {
    echo -ne " ${HOLD} ${YL}${1}...${CL}"
}

function msg_ok() {
    echo -e "${BFR} ${CM} ${GN}$1${CL}"
}

function msg_warn() {
    echo -e "${BFR} ${WARN} ${YL}Warning:${CL} $1"
}

function msg_error() {
    echo -e "${BFR} ${CROSS} ${RD}$1${CL}"
}

#################################################################################
# VM Interaction Functions                                                       #
#################################################################################

function send_line_to_vm() {
    local line="$1"
    echo -e "${DGN}Sending line: ${BL}$1${CL}"
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
    qm sendkey $VMID ret
}

function press_enter() {
    qm sendkey $VMID ret
    sleep 0.5
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
SERIAL_CONSOLE="yes"
IP_ADDR=""
WAN_IP_ADDR=""
LAN_GW=""
WAN_GW=""
NETMASK=""
WAN_NETMASK=""
NETWORK_MODE=""
BRIDGE1=""
BRIDGE2=""
BRIDGE3=""
MAC1=""
MAC2=""
MAC3=""
MTU1=""
MTU2=""
MTU3=""
VLAN1=""
VLAN2=""
VLAN3=""
START_VM="yes"
HN=""
CPU_TYPE=""
CORE_COUNT=""
RAM_SIZE=""
DISK_SIZE=""
DISK_CACHE=""
MACHINE=""
BIOS_TYPE=""
VM_TAGS=""
ISO_BASENAME=""
FREEBSD_QCOW2=""

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
        msg_info "Cleaning up VM $VMID"
        qm status "$VMID" | grep -q "running" && qm stop "$VMID" &>/dev/null || true
        sleep 2
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
    # Define the list of required commands
    local deps=(whiptail pvesh pvesm qm wget curl bunzip2 genisoimage)
    local optional_deps=(xmlstarlet unxz)

    # Map each command to its corresponding Debian package
    declare -A cmd_pkg_map=(
        [whiptail]=whiptail
        [pvesh]=pve-manager
        [pvesm]=pve-manager
        [qm]=qemu-utils
        [wget]=wget
        [curl]=curl
        [bunzip2]=bzip2
        [genisoimage]=genisoimage
        [xmlstarlet]=xmlstarlet
        [unxz]=xz-utils
    )

    # Check for optional dependencies
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "$cmd is not installed. Some functionality will be limited."
            if [[ "$cmd" == "xmlstarlet" ]]; then
                echo -e "  - Without xmlstarlet, a fallback method will be used for XML processing."
                echo -e "  - For best results, consider installing xmlstarlet: apt-get install xmlstarlet"
                echo
            elif [[ "$cmd" == "unxz" ]]; then
                echo -e "  - Without unxz, FreeBSD installation method won't work."
                echo -e "  - Consider installing xz-utils: apt-get install xz-utils"
                echo
            fi
        fi
    done

    # Array to hold missing packages
    local missing_pkgs=()

    # Iterate through each required command to check its existence
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg=${cmd_pkg_map[$cmd]}
            if [ -z "$pkg" ]; then
                msg_error "No package mapping found for command '$cmd'. Please install it manually."
                exit 1
            fi
            missing_pkgs+=("$pkg")
        fi
    done

    # If no dependencies are missing, exit the function
    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        msg_ok "All required dependencies are already installed."
        return 0
    fi

    # Flag to check if 'apt-get update' has been run
    local updated=false

    # Iterate through each missing package to prompt installation
    for pkg in "${missing_pkgs[@]}"; do
        while true; do
            read -rp "Package '$pkg' is required but not installed. Install it now? (y/n): " choice
            case "$choice" in
                y|Y )
                    # Run 'apt-get update' once before the first installation
                    if [ "$updated" = false ]; then
                        msg_info "Updating package lists"
                        if ! apt-get update; then
                            msg_error "Failed to update package lists. Please check your network connection."
                            exit 1
                        fi
                        updated=true
                    fi

                    # Install the package
                    msg_info "Installing package '$pkg'"
                    if apt-get install -y "$pkg"; then
                        msg_ok "Package '$pkg' installed successfully."
                    else
                        msg_error "Failed to install package '$pkg'. Please install it manually."
                        exit 1
                    fi
                    break
                    ;;
                n|N )
                    msg_error "Required package '$pkg' is not installed. Exiting."
                    exit 1
                    ;;
                * )
                    echo "Please answer y (yes) or n (no)."
                    ;;
            esac
        done
    done

    msg_ok "All missing dependencies have been handled."
}

# Enhanced function to get a valid next VM ID
function get_valid_nextid() {
    local try_id
    try_id=$(pvesh get /cluster/nextid 2>/dev/null || echo $STARTING_VM_ID)
    
    while true; do
        # Check if ID is used by a VM
        if [ -f "/etc/pve/qemu-server/${try_id}.conf" ]; then
            try_id=$((try_id + 1))
            continue
        fi
        
        # Check if ID is used by a container
        if [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
            try_id=$((try_id + 1))
            continue
        fi
        
        # Check if ID is used in LVM
        if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
            try_id=$((try_id + 1))
            continue
        fi
        
        break
    done
    
    echo "$try_id"
}

function check_vmid {
    # Using the improved function from above
    NEXTID=$(get_valid_nextid)
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
    local PVE_VER
    PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

    # Proxmox VE 8.x: allow 8.0-8.9
    if [[ "$PVE_VER" =~ ^8\.([0-9]+) ]]; then
        local MINOR="${BASH_REMATCH[1]}"
        if ((MINOR < 0 || MINOR > 9)); then
            msg_error "This version of Proxmox VE is not supported."
            msg_error "Supported: Proxmox VE version 8.0 - 8.9"
            exit 1
        fi
        return 0
    fi

    # Proxmox VE 9.x: allow 9.0-9.1
    if [[ "$PVE_VER" =~ ^9\.([0-9]+) ]]; then
        local MINOR="${BASH_REMATCH[1]}"
        if ((MINOR < 0 || MINOR > 1)); then
            msg_error "This version of Proxmox VE is not supported."
            msg_error "Supported: Proxmox VE version 9.0 - 9.1"
            exit 1
        fi
        return 0
    fi

    # All other unsupported versions
    msg_error "This version of Proxmox VE is not supported."
    msg_error "Supported versions: Proxmox VE 8.0 - 8.9 or 9.0 - 9.1"
    exit 1
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

function verify_bridge_exists() {
    local bridge="$1"
    local purpose="$2"
    
    if ! grep -q "^iface ${bridge}" /etc/network/interfaces; then
        msg_warn "Bridge '${bridge}' for ${purpose} does not exist in /etc/network/interfaces"
        local create_bridge=""
        read -rp "Would you like to create this bridge? (y/n): " create_bridge
        case "$create_bridge" in
            y|Y)
                # Simple bridge creation - can be enhanced
                echo -e "\nauto $bridge\niface $bridge inet manual\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                msg_ok "Bridge '$bridge' has been added to /etc/network/interfaces"
                echo "Note: You may need to restart networking or reboot for changes to take effect."
                ;;
            *)
                msg_error "Bridge '$bridge' is required but not available. Please create it manually."
                if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --title "BRIDGE NOT FOUND" \
                    --yesno "Bridge '$bridge' does not exist. Continue anyway? (Not recommended)" 10 62; then
                    exit 1
                fi
                ;;
        esac
    else
        msg_ok "Bridge '$bridge' exists"
    fi
}

#################################################################################
# Storage Selection Functions                                                   #
#################################################################################

# Enhanced storage validation function
function validate_storage() {
    msg_info "Validating Storage"
    local storage_menu=()
    local msg_max_length=0
    
    while read -r line; do
        local tag=$(echo $line | awk '{print $1}')
        local type=$(echo $line | awk '{printf "%-10s", $2}')
        local free=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
        local item="  Type: $type Free: $free "
        local offset=2
        
        if [[ $((${#item} + $offset)) -gt ${msg_max_length} ]]; then
            msg_max_length=$((${#item} + $offset))
        fi
        
        storage_menu+=("$tag" "$item" "OFF")
    done < <(pvesm status -content images | awk 'NR>1')
    
    local valid=$(pvesm status -content images | awk 'NR>1')
    if [ -z "$valid" ]; then
        msg_error "Unable to detect a valid storage location."
        exit 1
    fi
    
    echo "${storage_menu[@]}"
}

function select_iso_storage() {
    local title="ISO STORAGE"
    local prompt="Which storage pool would you like to use for the OPNsense ISO?"
    local menu_items=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
        [[ -z "$tag" ]] && continue
        local item="Type: $stype, Free: $free"
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
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
        [[ -z "$tag" ]] && continue
        local item="Type: $stype, Free: $free"
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

function select_config_storage() {
    local title="$1"
    local prompt="$2"
    local menu_items=()
    # We look for storages that can hold ISOs
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag=$(echo "$line" | awk '{print $1}')
        local stype=$(echo "$line" | awk '{print $2}')
        local free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
        [[ -z "$tag" ]] && continue
        local item="Type: $stype, Free: $free"
        menu_items+=("$tag" "$item")
    done < <(pvesm status -content iso)

    if [ ${#menu_items[@]} -eq 0 ]; then
        msg_error "No valid storage found for storing configuration ISO. Exiting..."
        exit 1
    fi

    local chosen_config_storage
    chosen_config_storage=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "$title" \
        --menu "$prompt" 16 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script

    echo "$chosen_config_storage"
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
    BIOS_TYPE="ovmf"
    MACHINE="q35"
    DISK_CACHE=""
    HN="opnsense"
    CPU_TYPE="host"
    CORE_COUNT="4"
    RAM_SIZE="8192"
    DISK_SIZE="30G"
    EFI_DISK_SIZE="8M"
    AUTOMATE_SETUP="no"
    SERIAL_CONSOLE="yes"
    VM_TAGS="opnsense,firewall"
    IP_ADDR=""
    WAN_IP_ADDR=""
    LAN_GW=""
    WAN_GW=""
    NETMASK=""
    WAN_NETMASK=""
    NETWORK_MODE="dual"

    echo -e "${DGN}Using Virtual Machine ID: ${BGN}${VMID}${CL}"
    echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
    echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
    echo -e "${DGN}Allocated RAM: ${BGN}${RAM_SIZE}${CL}"

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        BRIDGE1="$DEFAULT_WAN_BRIDGE"
        MAC1=$(generate_mac)
        MTU1="1500"
        VLAN1=""

        if ! grep -q "^iface ${BRIDGE1}" /etc/network/interfaces 2>/dev/null; then
            msg_warn "Bridge '${BRIDGE1}' does not exist in /etc/network/interfaces"
        else
            echo -e "${DGN}Using LAN Bridge: ${BGN}${BRIDGE1}${CL}"
        fi
        echo -e "${DGN}Using LAN MAC Address: ${BGN}${MAC1}${CL}"

        # Network mode selection: dual (firewall/router) or single (proxy/VPN/IDS)
        if NETWORK_MODE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "NETWORK CONFIGURATION" --radiolist --cancel-button "Exit Script" \
            "Choose network setup mode for OPNsense:\n" 14 70 2 \
            "dual" "Dual Interface (Traditional Firewall/Router)" ON \
            "single" "Single Interface (Proxy/VPN/IDS Server)" OFF \
            3>&1 1>&2 2>&3); then
            if [ "$NETWORK_MODE" = "dual" ]; then
                echo -e "${DGN}Network Mode: ${BGN}Dual Interface (Firewall)${CL}"
                BRIDGE2="$DEFAULT_LAN_BRIDGE"
                MAC2=$(generate_mac)
                MTU2="1500"
                VLAN2=""
                echo -e "${DGN}Using WAN MAC Address: ${BGN}${MAC2}${CL}"
                if ! grep -q "^iface ${BRIDGE2}" /etc/network/interfaces 2>/dev/null; then
                    msg_warn "Bridge '${BRIDGE2}' does not exist in /etc/network/interfaces"
                else
                    echo -e "${DGN}Using WAN Bridge: ${BGN}${BRIDGE2}${CL}"
                fi
                BRIDGE3="$DEFAULT_MGMT_BRIDGE"
                MAC3=$(generate_mac)
                MTU3="1500"
                VLAN3=""
            else
                echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
                BRIDGE2=""
                MAC2=""
                MTU2=""
                VLAN2=""
                BRIDGE3=""
                MAC3=""
                MTU3=""
                VLAN3=""
            fi
        else
            exit_script
        fi
    fi

    START_VM="yes"
    echo -e "${DGN}Using Interface MTU Size: ${BGN}Default${CL}"
    echo -e "${DGN}Start VM when completed: ${BGN}yes${CL}"
    echo -e "${BL}Creating an OPNsense VM using the above default settings${CL}"
    msg_ok "Default settings applied."
}

function advanced_settings() {
    local ip_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    IP_ADDR=""
    WAN_IP_ADDR=""
    LAN_GW=""
    WAN_GW=""
    NETMASK=""
    WAN_NETMASK=""

    check_vmid
    while true; do
        VMID=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Set Virtual Machine ID" 8 58 "$NEXTID" \
            --title "VIRTUAL MACHINE ID" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        if [ -z "$VMID" ]; then
            VMID="$NEXTID"
        fi
        if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
            echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"
            sleep 2
            continue
        fi
        echo -e "${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
        break
    done

    if MACH=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "MACHINE TYPE" --radiolist --cancel-button "Exit Script" "Choose Type" 10 58 2 \
        "i440fx" "Machine i440fx" ON \
        "q35" "Machine q35" OFF \
        3>&1 1>&2 2>&3); then
        if [ "$MACH" = "q35" ]; then
            MACHINE="q35"
            BIOS_TYPE="ovmf"
        else
            MACHINE="pc"
            BIOS_TYPE="ovmf"
        fi
        echo -e "${DGN}Using Machine Type: ${BGN}$MACH${CL}"
    else
        exit_script
    fi

    if CPU_TYPE1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "CPU MODEL" --radiolist "Choose" --cancel-button "Exit Script" 10 58 2 \
        "0" "KVM64 (Default)" ON \
        "1" "Host" OFF \
        3>&1 1>&2 2>&3); then
        if [ "$CPU_TYPE1" = "1" ]; then
            CPU_TYPE="host"
            echo -e "${DGN}Using CPU Model: ${BGN}Host${CL}"
        else
            CPU_TYPE="kvm64"
            echo -e "${DGN}Using CPU Model: ${BGN}KVM64${CL}"
        fi
    else
        exit_script
    fi

    if DISK_CACHE_SEL=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "DISK CACHE" --radiolist "Choose" --cancel-button "Exit Script" 10 58 2 \
        "0" "None (Default)" ON \
        "1" "Write Through" OFF \
        3>&1 1>&2 2>&3); then
        if [ "$DISK_CACHE_SEL" = "1" ]; then
            DISK_CACHE="writethrough"
            echo -e "${DGN}Using Disk Cache: ${BGN}Write Through${CL}"
        else
            DISK_CACHE=""
            echo -e "${DGN}Using Disk Cache: ${BGN}None${CL}"
        fi
    else
        exit_script
    fi

    if VM_NAME=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Set Hostname" 8 58 "opnsense" \
        --title "HOSTNAME" --cancel-button "Exit Script" 3>&1 1>&2 2<&3); then
        if [ -z "$VM_NAME" ]; then
            HN="opnsense"
        else
            HN=$(echo "${VM_NAME,,}" | tr -d ' ')
        fi
        echo -e "${DGN}Using Hostname: ${BGN}$HN${CL}"
    else
        exit_script
    fi

    CORE_COUNT=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Allocate CPU Cores" 8 58 4 \
        --title "CORE COUNT" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$CORE_COUNT" ]; then CORE_COUNT="4"; fi
    echo -e "${DGN}Allocated Cores: ${BGN}$CORE_COUNT${CL}"

    RAM_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Allocate RAM in MiB" 8 58 8192 \
        --title "RAM" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$RAM_SIZE" ]; then RAM_SIZE="8192"; fi
    echo -e "${DGN}Allocated RAM: ${BGN}$RAM_SIZE${CL}"

    DISK_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Disk size (Default: 30G)" 8 60 "30G" \
        --title "DISK SIZE" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$DISK_SIZE" ]; then DISK_SIZE="30G"; fi

    EFI_DISK_SIZE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "EFI Disk size (Default: 8M)" 8 60 "8M" \
        --title "EFI DISK SIZE" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$EFI_DISK_SIZE" ]; then EFI_DISK_SIZE="8M"; fi

    # Serial console option
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "SERIAL CONSOLE" \
        --yesno "Enable serial console?" 10 60 --yes-button "Yes" \
        --no-button "No" --cancel-button "Exit Script"); then
        SERIAL_CONSOLE="yes"
    else
        SERIAL_CONSOLE="no"
    fi

    # VM tags
    VM_TAGS=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "VM Tags (comma-separated)" 8 60 "opnsense,firewall" \
        --title "VM TAGS" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        # LAN Bridge
        if BRIDGE1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Set a LAN Bridge" 8 58 "$DEFAULT_WAN_BRIDGE" \
            --title "LAN BRIDGE" --cancel-button "Exit Script" 3>&1 1>&2 2>&3); then
            if [ -z "$BRIDGE1" ]; then BRIDGE1="$DEFAULT_WAN_BRIDGE"; fi
            if ! grep -q "^iface ${BRIDGE1}" /etc/network/interfaces 2>/dev/null; then
                msg_warn "Bridge '${BRIDGE1}' does not exist in /etc/network/interfaces"
            fi
            echo -e "${DGN}Using LAN Bridge: ${BGN}$BRIDGE1${CL}"
        else
            exit_script
        fi

        # LAN IP Address
        if IP_ADDR=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Set a LAN IP (leave empty for DHCP)" 8 58 "" \
            --title "LAN IP ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2>&3); then
            if [ -z "$IP_ADDR" ]; then
                echo -e "${DGN}Using DHCP as LAN IP ADDRESS${CL}"
            else
                if [[ -n "$IP_ADDR" && ! "$IP_ADDR" =~ $ip_regex ]]; then
                    msg_error "Invalid IP Address format for LAN IP. Needs to be x.x.x.x, was $IP_ADDR"
                    exit 1
                fi
                echo -e "${DGN}Using LAN IP ADDRESS: ${BGN}$IP_ADDR${CL}"

                LAN_GW=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Set a LAN Gateway IP" 8 58 "" \
                    --title "LAN GATEWAY IP ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
                if [ -z "$LAN_GW" ]; then
                    msg_error "Gateway needs to be set if IP is not DHCP"
                    exit_script
                fi
                if [[ ! "$LAN_GW" =~ $ip_regex ]]; then
                    msg_error "Invalid IP Address format for Gateway. Needs to be x.x.x.x, was $LAN_GW"
                    exit 1
                fi
                echo -e "${DGN}Using LAN GATEWAY ADDRESS: ${BGN}$LAN_GW${CL}"

                NETMASK=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Set a LAN netmask (e.g. 24)" 8 58 "" \
                    --title "LAN NETMASK" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
                if [ -z "$NETMASK" ]; then
                    msg_error "Netmask needs to be set if IP is not DHCP"
                    exit_script
                fi
                if [[ ! ("$NETMASK" =~ ^[0-9]+$ && "$NETMASK" -ge 1 && "$NETMASK" -le 32) ]]; then
                    msg_error "Invalid LAN NETMASK format. Needs to be 1-32, was $NETMASK"
                    exit 1
                fi
                echo -e "${DGN}Using LAN NETMASK: ${BGN}$NETMASK${CL}"
            fi
        else
            exit_script
        fi

        MAC1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Set a LAN MAC Address" 8 58 "$(generate_mac)" \
            --title "LAN MAC ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU1="1500"
        VLAN1=""

        # WAN Bridge
        if BRIDGE2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Set a WAN Bridge (leave empty for single-interface mode)" 8 58 "$DEFAULT_LAN_BRIDGE" \
            --title "WAN BRIDGE" --cancel-button "Exit Script" 3>&1 1>&2 2>&3); then
            if [ -n "$BRIDGE2" ]; then
                if ! grep -q "^iface ${BRIDGE2}" /etc/network/interfaces 2>/dev/null; then
                    msg_warn "WAN Bridge '${BRIDGE2}' does not exist in /etc/network/interfaces"
                fi
                echo -e "${DGN}Using WAN Bridge: ${BGN}$BRIDGE2${CL}"

                # WAN IP Address
                if WAN_IP_ADDR=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Set a WAN IP (leave empty for DHCP)" 8 58 "" \
                    --title "WAN IP ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2>&3); then
                    if [ -z "$WAN_IP_ADDR" ]; then
                        echo -e "${DGN}Using DHCP as WAN IP ADDRESS${CL}"
                    else
                        if [[ ! "$WAN_IP_ADDR" =~ $ip_regex ]]; then
                            msg_error "Invalid IP Address format for WAN IP. Needs to be x.x.x.x, was $WAN_IP_ADDR"
                            exit 1
                        fi
                        echo -e "${DGN}Using WAN IP ADDRESS: ${BGN}$WAN_IP_ADDR${CL}"

                        WAN_GW=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                            --inputbox "Set a WAN Gateway IP" 8 58 "" \
                            --title "WAN GATEWAY IP ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
                        if [ -z "$WAN_GW" ]; then
                            msg_error "Gateway needs to be set if IP is not DHCP"
                            exit_script
                        fi
                        if [[ ! "$WAN_GW" =~ $ip_regex ]]; then
                            msg_error "Invalid IP Address format for WAN Gateway. Needs to be x.x.x.x, was $WAN_GW"
                            exit 1
                        fi
                        echo -e "${DGN}Using WAN GATEWAY ADDRESS: ${BGN}$WAN_GW${CL}"

                        WAN_NETMASK=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                            --inputbox "Set a WAN netmask (e.g. 24)" 8 58 "" \
                            --title "WAN NETMASK" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
                        if [ -z "$WAN_NETMASK" ]; then
                            msg_error "WAN Netmask needs to be set if IP is not DHCP"
                            exit_script
                        fi
                        if [[ ! ("$WAN_NETMASK" =~ ^[0-9]+$ && "$WAN_NETMASK" -ge 1 && "$WAN_NETMASK" -le 32) ]]; then
                            msg_error "Invalid WAN NETMASK format. Needs to be 1-32, was $WAN_NETMASK"
                            exit 1
                        fi
                        echo -e "${DGN}Using WAN NETMASK: ${BGN}$WAN_NETMASK${CL}"
                    fi
                else
                    exit_script
                fi

                MAC2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Set a WAN MAC Address" 8 58 "$(generate_mac)" \
                    --title "WAN MAC ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
                MTU2="1500"
                VLAN2=""
            else
                echo -e "${DGN}Network Mode: ${BGN}Single Interface (Proxy/VPN/IDS)${CL}"
                MAC2=""
                MTU2=""
                VLAN2=""
            fi
        else
            exit_script
        fi

        # MGMT Interface configuration
        BRIDGE3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (MGMT) DEFAULT: $DEFAULT_MGMT_BRIDGE (leave empty to skip)" 8 60 "$DEFAULT_MGMT_BRIDGE" \
            --title "INTERFACE NAME (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        if [ -n "$BRIDGE3" ]; then
            MAC3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --inputbox "MAC Address for MGMT" 8 60 "$(generate_mac)" \
                --title "MAC ADDRESS (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
            MTU3="1500"
            VLAN3=""
        else
            MAC3=""
            MTU3=""
            VLAN3=""
        fi
    fi

    # Installation method
    if INSTALL_METHOD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "INSTALLATION METHOD" --radiolist "Choose installation method:" 10 60 2 \
        "iso" "ISO Installation (Traditional)" ON \
        "freebsd" "FreeBSD base (Alternative)" OFF \
        3>&1 1>&2 2<&3 --cancel-button "Exit Script"); then
        INSTALLATION_METHOD="$INSTALL_METHOD"
        echo -e "${DGN}Using Installation Method: ${BGN}$INSTALLATION_METHOD${CL}"
    else
        exit_script
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "START VIRTUAL MACHINE" \
        --yesno "Start VM when completed?" 10 60 --yes-button "Yes" \
        --no-button "No" --cancel-button "Exit Script"); then
        START_VM="yes"
    else
        START_VM="no"
    fi

    echo -e "${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
    echo -e "${DGN}Using Machine Type: ${BGN}${MACHINE}${CL}"
    echo -e "${DGN}Using Hostname: ${BGN}${HN}${CL}"
    echo -e "${DGN}Using CPU Model: ${BGN}${CPU_TYPE}${CL}"
    echo -e "${DGN}Allocated Cores: ${BGN}${CORE_COUNT}${CL}"
    echo -e "${DGN}Allocated RAM: ${BGN}${RAM_SIZE}${CL}"
    echo -e "${DGN}Using Installation Method: ${BGN}${INSTALLATION_METHOD}${CL}"
    echo -e "${DGN}Serial Console: ${BGN}${SERIAL_CONSOLE}${CL}"
    echo -e "${DGN}VM Tags: ${BGN}${VM_TAGS}${CL}"
    echo -e "${DGN}Start VM when completed: ${BGN}${START_VM}${CL}"

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ADVANCED SETTINGS COMPLETE" \
        --yesno "Ready to create OPNsense VM?" --no-button "Do-Over" 10 58); then
        echo -e "${RD}Creating an OPNsense VM using the above advanced settings${CL}"
    else
        header_info
        echo -e "${RD}Using Advanced Settings${CL}"
        advanced_settings
    fi
}

function select_installation_method() {
    if INSTALL_METHOD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "INSTALLATION METHOD" --radiolist "Choose installation method:" 10 60 2 \
        "iso" "ISO Installation (Traditional)" ON \
        "freebsd" "FreeBSD base (Alternative)" OFF \
        3>&1 1>&2 2<&3 --cancel-button "Exit Script"); then
        INSTALLATION_METHOD="$INSTALL_METHOD"
        echo -e "${DGN}Using Installation Method: ${BGN}$INSTALLATION_METHOD${CL}"
    else
        exit_script
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
    # First password entry
    ROOT_PASSWORD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ROOT PASSWORD" --passwordbox "Enter root password:" 10 60 \
        --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    
    if [ -z "$ROOT_PASSWORD" ]; then
        msg_error "No password entered. Exiting..."
        exit 1
    fi
    
    # Confirm password
    CONFIRM_PASSWORD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "CONFIRM ROOT PASSWORD" --passwordbox "Confirm root password:" 10 60 \
        --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    
    # Check if passwords match
    if [ "$ROOT_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        msg_error "Passwords do not match. Please try again."
        prompt_root_password
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
# Functions for obtaining and handling ISOs
#################################################################################

function parse_available_versions() {
    msg_info "Parsing available OPNsense versions from mirror"
    local html_content
    html_content=$(curl -s "$MIRROR_BASE_URL" || true)

    ISO_ENTRIES=()
    local version_dirs

    # Modified pattern to catch all version formats
    version_dirs=$(echo "$html_content" \
        | grep -oP 'href="\K[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.?[a-z]+)?(?=/)' \
        | sort -V || true)

    echo "Debug: Found version directories: $version_dirs"

    for version in $version_dirs; do
        local version_url="${MIRROR_BASE_URL}${version}/"
        local version_content
        version_content=$(curl -s "$version_url" || true)

        echo "Debug: Checking $version_url"

        # Look for both regular and development ISOs
        local iso_files
        if echo "$version_content" | grep -q "OPNsense-devel-"; then
            # Development version
            iso_files=$(echo "$version_content" | grep -o 'OPNsense-devel-[^"]*-amd64\.iso\.bz2' || true)
        else
            # Regular version
            iso_files=$(echo "$version_content" | grep -o 'OPNsense-[^"]*-dvd-amd64\.iso\.bz2' || true)
        fi

        while IFS= read -r iso_file; do
            [[ -z "$iso_file" ]] && continue

            echo "Debug: Found ISO file: $iso_file"

            # Extract date from listing
            local date_part
            date_part=$(echo "$version_content" \
                | grep -A1 "$iso_file" \
                | grep -oP '\d{2}-[A-Za-z]{3}-\d{4}' || true)

            if [[ -z "$date_part" ]]; then
                date_part=$(date +"%d-%b-%Y")
            fi

            echo "Debug: Release date: $date_part"

            # Convert date_part to YYYYMMDD
            local formatted_date
            formatted_date=$(convert_date "$(echo "$date_part" | awk -F'-' '{print $3"-"$2"-"$1}')")

            # Store the full URL and other details
            ISO_ENTRIES+=("${version_url}${iso_file}|${formatted_date}-${iso_file}|${date_part}|${version}")
            echo "Debug: Added entry: ${version_url}${iso_file}|${formatted_date}-${iso_file}|${date_part}|${version}"
        done <<< "$iso_files"
    done

    echo "Debug: Total entries found: ${#ISO_ENTRIES[@]}"
}

function select_iso() {
    if [ "$INSTALLATION_METHOD" != "iso" ]; then
        return
    fi
    
    # Try to parse available versions, only if we have internet connectivity
    if ping -c 1 mirrors.ocf.berkeley.edu &>/dev/null; then
        parse_available_versions
    else
        msg_warn "No internet connectivity detected. Skipping version check from mirror."
        ISO_ENTRIES=()
    fi

    MENU_ITEMS=()
    # Always add fallback first
    MENU_ITEMS+=("$FALLBACK_URL" "OPNsense $FALLBACK_VERSION")

    if [ ${#ISO_ENTRIES[@]} -ne 0 ]; then
        local sorted_entries=()
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r url filename date version <<< "$entry"
            sorted_entries+=("$entry")
        done

        IFS=$'\n' sorted_entries=($(sort -t'|' -k4,4Vr <<<"${sorted_entries[*]}"))
        unset IFS

        for entry in "${sorted_entries[@]}"; do
            IFS='|' read -r url filename date version <<< "$entry"
            MENU_ITEMS+=("$url" "OPNsense $version")
        done
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
                iso_basename="$filename"
                break
            fi
        done

        # If not found, default to fallback naming
        if [ -z "$iso_basename" ]; then
            formatted_date=$(convert_date "$FALLBACK_RELEASE_DATE")
            iso_basename="${formatted_date}-$(basename "$FALLBACK_URL")"
        fi
    fi
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
        # e.g. "20240723-OPNsense-24.7-dvd-amd64.iso" => do nothing
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
    
    # Check both in official templates dir and user-provided ISOs
    local iso_dirs=("/var/lib/vz/template/iso" "$(pvesm path "$ISO_STORAGE")/template/iso")
    
    for iso_dir in "${iso_dirs[@]}"; do
        if [ -d "$iso_dir" ]; then
            while IFS= read -r iso_file; do
                if [[ "$iso_file" == *OPNsense* && "$iso_file" == *.iso ]]; then
                    ISO_LIST+=("$(basename "$iso_file")" "OPNsense ISO")
                elif [[ "$iso_file" == *.iso ]]; then
                    ISO_LIST+=("$(basename "$iso_file")" "Other ISO file")
                fi
            done < <(find "$iso_dir" -type f -name "*.iso" 2>/dev/null)
        fi
    done

    if [ ${#ISO_LIST[@]} -eq 0 ]; then
        msg_error "No .iso files found in ISO storage locations."
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

    msg_ok "Using local ISO: $ISO_BASENAME"
}

function handle_freebsd_download() {
    if [ "$INSTALLATION_METHOD" != "freebsd" ]; then
        return
    fi

    # Check if unxz is available
    if ! command -v unxz &>/dev/null; then
        msg_error "unxz is not installed. Cannot extract FreeBSD image."
        msg_info "Install it with: apt-get install xz-utils"
        exit 1
    fi

    # Check if we have internet connectivity
    if ! ping -c 1 download.freebsd.org &>/dev/null; then
        msg_error "No internet connectivity. Cannot download FreeBSD image."
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "NO INTERNET" \
            --yesno "No internet connectivity detected. Switch to ISO installation method?" 10 60); then
            INSTALLATION_METHOD="iso"
            select_iso
            return
        else
            exit 1
        fi
    fi

    # Dynamically discover the latest stable FreeBSD amd64 qcow2 VM image
    msg_info "Retrieving the URL for the FreeBSD Qcow2 Disk Image"
    local RELEASE_LIST
    RELEASE_LIST="$(curl -s https://download.freebsd.org/releases/VM-IMAGES/ |
        grep -Eo '[0-9]+\.[0-9]+-RELEASE' |
        sort -Vr |
        uniq)"

    local DISCOVERED_URL=""
    local FREEBSD_VER=""
    for ver in $RELEASE_LIST; do
        local candidate="https://download.freebsd.org/releases/VM-IMAGES/${ver}/amd64/Latest/FreeBSD-${ver}-amd64.qcow2.xz"
        if curl -fsI "$candidate" >/dev/null 2>&1; then
            FREEBSD_VER="$ver"
            DISCOVERED_URL="$candidate"
            break
        fi
    done

    if [ -z "$DISCOVERED_URL" ]; then
        msg_warn "Could not find latest FreeBSD release dynamically. Using fallback URL."
        DISCOVERED_URL="$FREEBSD_URL"
        FREEBSD_VER="14.2-RELEASE"
    fi

    msg_ok "Found FreeBSD $FREEBSD_VER: ${DISCOVERED_URL}"

    local temp_dir=$(mktemp -d)
    local download_file="$(basename "$DISCOVERED_URL")"

    msg_info "Downloading FreeBSD image for OPNsense installation"
    if ! curl -f#SL -o "$temp_dir/$download_file" "$DISCOVERED_URL"; then
        msg_error "Failed to download FreeBSD image"
        rm -rf "$temp_dir"
        exit 1
    fi

    msg_ok "Downloaded FreeBSD image"
    msg_info "Extracting FreeBSD image..."

    local freebsd_file="FreeBSD.qcow2"
    if ! unxz -cv "$temp_dir/$download_file" > "$temp_dir/$freebsd_file"; then
        msg_error "Failed to extract FreeBSD image"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Store reference to the extracted file
    FREEBSD_QCOW2="$temp_dir/$freebsd_file"

    msg_ok "Extracted FreeBSD image: $freebsd_file"
}

#################################################################################
# Network Configuration Functions
#################################################################################

function prompt_network_configuration() {
    local ip_regex='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    
    LAN_IPV4=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Enter LAN IPv4 Address (leave empty for DHCP):" 8 60 --title "LAN IPv4 ADDRESS" \
        --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
    
    if [ -n "$LAN_IPV4" ]; then
        if [[ ! "$LAN_IPV4" =~ $ip_regex ]]; then
            msg_error "Invalid IP address format. Should be like 192.168.1.1"
            prompt_network_configuration
            return
        fi
        
        SUBNET_MASK=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter Subnet Mask (CIDR format, e.g., 24):" 8 60 \
            --title "SUBNET MASK" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        
        if [ -z "$SUBNET_MASK" ]; then
            msg_error "No Subnet Mask entered. Exiting..."
            exit 1
        fi
        
        # Validate subnet mask is a number between 1-32
        if ! [[ "$SUBNET_MASK" =~ ^[0-9]+$ ]] || [ "$SUBNET_MASK" -lt 1 ] || [ "$SUBNET_MASK" -gt 32 ]; then
            msg_error "Invalid subnet mask. Must be a number between 1 and 32."
            prompt_network_configuration
            return
        fi
    else
        msg_ok "Using DHCP for LAN interface"
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "DHCP SERVER" --yesno "Enable DHCP Server?" \
        10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        ENABLE_DHCP="yes"
        
        # Only prompt for DHCP range if a static IP was set
        if [ -n "$LAN_IPV4" ]; then
            # Calculate network range based on IP and subnet mask
            IFS='.' read -r i1 i2 i3 i4 <<< "$LAN_IPV4"
            local ip_decimal=$(( (i1<<24) + (i2<<16) + (i3<<8) + i4 ))
            local cidr=$SUBNET_MASK
            local netmask_decimal=$(( 0xffffffff - ((1 << (32-cidr)) - 1) ))
            local network_decimal=$(( ip_decimal & netmask_decimal ))
            local network_i1=$(( (network_decimal>>24) & 0xff ))
            local network_i2=$(( (network_decimal>>16) & 0xff ))
            local network_i3=$(( (network_decimal>>8) & 0xff ))
            local network_i4=$(( network_decimal & 0xff ))
            
            # Suggested range: x.x.x.100 - x.x.x.200
            local suggested_start="${network_i1}.${network_i2}.${network_i3}.100"
            local suggested_end="${network_i1}.${network_i2}.${network_i3}.200"
            
            DHCP_START=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --inputbox "Start of DHCP range:" 8 60 "$suggested_start" \
                --title "DHCP RANGE START" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
            
            if [ -z "$DHCP_START" ] || [[ ! "$DHCP_START" =~ $ip_regex ]]; then
                msg_error "Invalid DHCP Start Range. Using default: $suggested_start"
                DHCP_START="$suggested_start"
            fi

            DHCP_END=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --inputbox "End of DHCP range:" 8 60 "$suggested_end" \
                --title "DHCP RANGE END" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
            
            if [ -z "$DHCP_END" ] || [[ ! "$DHCP_END" =~ $ip_regex ]]; then
                msg_error "Invalid DHCP End Range. Using default: $suggested_end"
                DHCP_END="$suggested_end"
            fi
        else
            msg_warn "Static IP needed for DHCP server configuration. DHCP server will not be configured."
            ENABLE_DHCP="no"
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
function create_vm() {
    msg_info "Starting creation of an OPNsense VM"

    # 1) Basic definitions
    local CREATION_DATE
    CREATION_DATE=$(date +'%Y-%m-%d')

    # (Optional) detect storage type => "dir", "zfspool", "lvmthin", etc.
    local STORAGE_TYPE
    STORAGE_TYPE=$(pvesm status | awk -v s="$VM_STORAGE" '$1 == s {print $2}')

    # Determine disk format and extension based on storage type
    local DISK_EXT=""
    local DISK_REF=""
    local DISK_IMPORT=""
    local THIN=""
    
    case $STORAGE_TYPE in
        nfs|dir)
            DISK_EXT=".qcow2"
            DISK_REF="$VMID/"
            DISK_IMPORT="-format qcow2"
            THIN=""
            ;;
        btrfs)
            DISK_EXT=".raw"
            DISK_REF="$VMID/"
            DISK_IMPORT="-format raw"
            THIN=""
            ;;
        lvm|lvmthin|zfspool)
            DISK_EXT=""
            DISK_REF=""
            DISK_IMPORT=""
            THIN=""
            ;;
        *)
            # Default for unknown storage types
            DISK_EXT=""
            DISK_REF=""
            DISK_IMPORT=""
            THIN=""
            ;;
    esac

    msg_info "Debug: VM_STORAGE='$VM_STORAGE' (type=$STORAGE_TYPE), ISO_STORAGE='$ISO_STORAGE'"
    msg_info "Debug: VMID='$VMID', EFI_DISK_SIZE='$EFI_DISK_SIZE', DISK_SIZE='$DISK_SIZE'"

    # Build VLAN parameters
    local VLAN_PARAMS=""
    if [ -n "${VLAN1:-}" ]; then VLAN_PARAMS="${VLAN_PARAMS},tag=${VLAN1}"; fi

    # 2) Create the VM shell with all options
    msg_info "Creating VM shell => ID=$VMID, Hostname=$HN"
    
    # Build the creation command
    local CREATE_CMD="qm create $VMID"
    CREATE_CMD="$CREATE_CMD -agent enabled=1"
    CREATE_CMD="$CREATE_CMD -tablet 0"
    CREATE_CMD="$CREATE_CMD -bios $BIOS_TYPE"
    CREATE_CMD="$CREATE_CMD -machine type=$MACHINE"
    CREATE_CMD="$CREATE_CMD -cpu $CPU_TYPE"
    CREATE_CMD="$CREATE_CMD -cores $CORE_COUNT"
    CREATE_CMD="$CREATE_CMD -memory $RAM_SIZE"
    CREATE_CMD="$CREATE_CMD -name $HN"
    CREATE_CMD="$CREATE_CMD -tags $VM_TAGS"
    CREATE_CMD="$CREATE_CMD -localtime 1"
    CREATE_CMD="$CREATE_CMD -onboot 1"
    CREATE_CMD="$CREATE_CMD -ostype l26"
    CREATE_CMD="$CREATE_CMD -scsihw virtio-scsi-pci"
    
    # Execute the creation command
    eval $CREATE_CMD

    # verify creation
    if ! qm status "$VMID" &>/dev/null; then
        msg_error "Failed to create VM shell for ID=$VMID. Exiting."
        exit 1
    fi

    # 3) Optionally add NICs if MANAGE_INTERFACES="yes"
    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        msg_info "Adding VirtIO NICs"

        # LAN interface (always present)
        local NET0_PARAMS="virtio,bridge=$BRIDGE1,macaddr=$MAC1"
        if [ "${MTU1:-1500}" != "1500" ]; then NET0_PARAMS="${NET0_PARAMS},mtu=$MTU1"; fi
        if [ -n "${VLAN1:-}" ]; then NET0_PARAMS="${NET0_PARAMS},tag=$VLAN1"; fi
        qm set "$VMID" -net0 "$NET0_PARAMS"
        msg_ok "LAN interface added (bridge=$BRIDGE1)"

        # WAN interface (only in dual-interface mode)
        if [ -n "${BRIDGE2:-}" ]; then
            local NET1_PARAMS="virtio,bridge=$BRIDGE2,macaddr=$MAC2"
            if [ "${MTU2:-1500}" != "1500" ]; then NET1_PARAMS="${NET1_PARAMS},mtu=$MTU2"; fi
            if [ -n "${VLAN2:-}" ]; then NET1_PARAMS="${NET1_PARAMS},tag=$VLAN2"; fi
            qm set "$VMID" -net1 "$NET1_PARAMS"
            msg_ok "WAN interface added (bridge=$BRIDGE2)"
        fi

        # MGMT interface (optional)
        if [ -n "${BRIDGE3:-}" ]; then
            local NET2_PARAMS="virtio,bridge=$BRIDGE3,macaddr=$MAC3"
            if [ "${MTU3:-1500}" != "1500" ]; then NET2_PARAMS="${NET2_PARAMS},mtu=$MTU3"; fi
            if [ -n "${VLAN3:-}" ]; then NET2_PARAMS="${NET2_PARAMS},tag=$VLAN3"; fi
            qm set "$VMID" -net2 "$NET2_PARAMS"
            msg_ok "MGMT interface added (bridge=$BRIDGE3)"
        fi

        msg_ok "Network interfaces added successfully"
    fi

    # Add serial console if enabled
    if [ "$SERIAL_CONSOLE" = "yes" ]; then
        qm set "$VMID" -serial0 socket
        msg_ok "Serial console enabled"
    fi

    ###########################################################################
    # 4) EFI Disk
    ###########################################################################
    msg_info "Creating EFI disk"
    local efi_index=0

    while true; do
        local efi_filename="vm-${VMID}-disk-${efi_index}${DISK_EXT}"
        local efi_storage_volume="${VM_STORAGE}:${DISK_REF}${efi_filename}"

        msg_info "Debug: Checking EFI disk => $efi_storage_volume"
        if volume_exists "$efi_storage_volume"; then
            if whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --title "Create VM Disks" \
                --yesno "Would you like to create the EFI disk?\n\nWarning: If a disk already exists with name '$efi_filename', it will be deleted." \
                12 70 --yes-button "Create" --no-button "Exit Script"; then
                
                msg_info "Removing existing EFI disk => $efi_storage_volume"
                if ! pvesm free "$efi_storage_volume"; then
                    msg_error "Could not remove existing EFI volume => $efi_storage_volume"
                    exit 1
                fi

                msg_info "Allocating EFI => $efi_filename (size=$EFI_DISK_SIZE)"
                pvesm alloc "$VM_STORAGE" "$VMID" "$efi_filename" "$EFI_DISK_SIZE" --format raw

                # Attach the EFI disk with proper format
                local efi_format=""
                if [ "$BIOS_TYPE" = "ovmf" ]; then
                    efi_format=",efitype=4m"
                fi
                qm set "$VMID" -efidisk0 "${efi_storage_volume}${efi_format}"
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

            local efi_format=""
            if [ "$BIOS_TYPE" = "ovmf" ]; then
                efi_format=",efitype=4m"
            fi
            qm set "$VMID" -efidisk0 "${efi_storage_volume}${efi_format}"
            msg_ok "EFI disk created & attached => $efi_storage_volume"
            break
        fi
    done

    ###########################################################################
    # 5) Main Disk
    ###########################################################################
    msg_info "Attaching main disk"
    local main_index=$((efi_index + 1))

    while true; do
        local main_filename="vm-${VMID}-disk-${main_index}${DISK_EXT}"
        local main_storage_volume="${VM_STORAGE}:${DISK_REF}${main_filename}"

        msg_info "Debug: Checking main disk => $main_storage_volume"
        if volume_exists "$main_storage_volume"; then
            if whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --title "Create VM Disks" \
                --yesno "Would you like to create the main disk?\n\nWarning: If a disk already exists with name '$main_filename', it will be deleted." \
                12 70 --yes-button "Create" --no-button "Exit Script"; then
                
                msg_info "Removing existing main disk => $main_storage_volume"
                if ! pvesm free "$main_storage_volume"; then
                    msg_error "Could not remove existing main volume => $main_storage_volume"
                    exit 1
                fi

                msg_info "Allocating main disk => $main_filename (size=$DISK_SIZE)"
                pvesm alloc "$VM_STORAGE" "$VMID" "$main_filename" "$DISK_SIZE" --format raw

                # Attach scsi0 with cache settings
                local cache_param=""
                if [ -n "$DISK_CACHE" ]; then
                    cache_param="cache=${DISK_CACHE},"
                fi

                local attached=false
                local RETRY_COUNT=5
                local RETRY_DELAY=3

                for ((attempt=1; attempt<=RETRY_COUNT; attempt++)); do
                    msg_info "Attempt $attempt: qm set $VMID -scsi0 ${main_storage_volume},${cache_param}${THIN}size=$DISK_SIZE"
                    if qm set "$VMID" -scsi0 "${main_storage_volume},${cache_param}${THIN}size=$DISK_SIZE"; then
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

            # Attach with cache settings
            local cache_param=""
            if [ -n "$DISK_CACHE" ]; then
                cache_param="cache=${DISK_CACHE},"
            fi

            local attached=false
            local RETRY_COUNT=5
            local RETRY_DELAY=3

            for ((attempt=1; attempt<=RETRY_COUNT; attempt++)); do
                msg_info "Attempt $attempt: qm set $VMID -scsi0 ${main_storage_volume},${cache_param}${THIN}size=$DISK_SIZE"
                if qm set "$VMID" -scsi0 "${main_storage_volume},${cache_param}${THIN}size=$DISK_SIZE"; then
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
    # 6) Attach the installation media (ISO or FreeBSD qcow2)
    ###########################################################################
    if [ "$INSTALLATION_METHOD" = "iso" ]; then
        # Using ISO installation method
        msg_info "Attaching ISO => $ISO_STORAGE:iso/$ISO_BASENAME"
        qm set "$VMID" -ide3 "$ISO_STORAGE:iso/$ISO_BASENAME,media=cdrom"
        qm set "$VMID" -boot c -bootdisk ide3
        msg_ok "ISO attached and set as boot device"
    else
        # Using FreeBSD qcow2 installation method
        if [ -n "$FREEBSD_QCOW2" ] && [ -f "$FREEBSD_QCOW2" ]; then
            msg_info "Importing FreeBSD qcow2 image"
            
            # Import the disk
            if ! qm importdisk "$VMID" "$FREEBSD_QCOW2" "$VM_STORAGE" ${DISK_IMPORT:-}; then
                msg_error "Failed to import FreeBSD qcow2 image"
                exit 1
            fi
            
            # Find the imported disk
            local imported_disk=$(qm config "$VMID" | grep -o 'unused[0-9]\+: .*' | head -n 1 | awk '{print $1}' | tr -d ':')
            
            if [ -n "$imported_disk" ]; then
                # Get the disk reference
                local disk_ref=$(qm config "$VMID" | grep "^$imported_disk:" | cut -d' ' -f2-)
                msg_info "Attaching imported disk as scsi1"
                qm set "$VMID" -scsi1 "$disk_ref"
                qm set "$VMID" -boot c -bootdisk scsi1
                msg_ok "FreeBSD image attached and set as boot device"
            else
                msg_error "Could not find imported disk. Manual configuration required."
            fi
        else
            msg_error "FreeBSD qcow2 file not found or not downloaded correctly"
            exit 1
        fi
    fi

    ###########################################################################
    # 7) Description and final setup
    ###########################################################################
    local description_text
    description_text=$(cat <<DESCEOF
<div align='center'>
  <a href='https://opnsense.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://opnsense.org/wp-content/themes/flavor/flavour-starter/assets/img/opnsense.png' alt='OPNsense Logo' style='width:120px;'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>OPNsense VM</h2>

  <p><strong>Created:</strong> $CREATION_DATE</p>
  <p><strong>Installation Method:</strong> $INSTALLATION_METHOD</p>
  <p><strong>OPNsense Version:</strong> $FALLBACK_VERSION</p>

  <hr style='margin: 20px 0;'>

  <p style='margin: 16px 0;'>
    <strong>Resources:</strong><br>
    CPU: $CORE_COUNT cores ($CPU_TYPE)<br>
    RAM: $RAM_SIZE MB<br>
    Disk: $DISK_SIZE
  </p>

  <p style='margin: 16px 0;'>
    <strong>Network Configuration:</strong><br>
DESCEOF
    )

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        description_text+="    LAN: Bridge ${BRIDGE1} (MAC: ${MAC1})<br>"
        if [ -n "${BRIDGE2:-}" ]; then
            description_text+="
    WAN: Bridge ${BRIDGE2} (MAC: ${MAC2})<br>"
        fi
        if [ -n "${BRIDGE3:-}" ]; then
            description_text+="
    MGMT: Bridge ${BRIDGE3} (MAC: ${MAC3})<br>"
        fi
    else
        description_text+="
    Manual network configuration required"
    fi

    description_text+="
  </p>
</div>"
    
    qm set "$VMID" -description "$description_text"
    
    msg_ok "Created an OPNsense VM (ID=$VMID) successfully!"
}

# Enhanced automate_install function with better error handling
function automate_install() {
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
        
        # Wait for initial boot with progress indicator
        msg_info "Waiting for VM to boot (this may take 2-3 minutes)"
        for i in {1..30}; do
            echo -n "."
            sleep 5
        done
        echo
        
        msg_info "VM booted, sending installer command"
        # Start the installer
        send_line_to_vm "installer"
        send_line_to_vm "opnsense"
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

        # Wait for installation with progress indicator
        msg_info "Installing OPNsense (this will take 5-6 minutes)"
        for i in {1..66}; do
            echo -n "."
            sleep 5
        done
        echo

        # Set root password
        press_enter
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
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
        qm set $VMID -delete ide3
        qm set $VMID -boot c -bootdisk scsi0
        # Start the VM
        qm start $VMID

        msg_info "Waiting for OPNsense to boot"
        sleep 80

        # Login as root
        send_line_to_vm "root"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2

        # Configure LAN interface
        send_line_to_vm "2"
        sleep 3

        if [ -n "$LAN_IPV4" ]; then
            send_line_to_vm "1"
            send_line_to_vm "n"
            send_line_to_vm "${LAN_IPV4}"
            send_line_to_vm "${SUBNET_MASK}"
            send_line_to_vm "${LAN_GW:-}"
            send_line_to_vm "n"
            send_line_to_vm " "
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm " "
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm "n"
        else
            send_line_to_vm "1"
            send_line_to_vm "y"
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm " "
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm "n"
        fi

        # Wait for config changes to be saved
        sleep 20

        # Configure WAN interface if dual-interface mode with static IP
        if [ -n "${BRIDGE2:-}" ] && [ -n "${WAN_IP_ADDR:-}" ]; then
            send_line_to_vm "2"
            send_line_to_vm "2"
            send_line_to_vm "n"
            send_line_to_vm "${WAN_IP_ADDR}"
            send_line_to_vm "${WAN_NETMASK:-24}"
            send_line_to_vm "${WAN_GW:-}"
            send_line_to_vm "n"
            send_line_to_vm " "
            send_line_to_vm "n"
            send_line_to_vm " "
            send_line_to_vm "n"
            send_line_to_vm "n"
            send_line_to_vm "n"
        fi

        sleep 10
        send_line_to_vm "0"
    }
    automate_setup "${LAN_IPV4:-}" "${SUBNET_MASK:-}" "${ENABLE_DHCP:-}" "${DHCP_START:-}" "${DHCP_END:-}" "${ENABLE_HTTPS:-}"
}

# Enhanced FreeBSD installation with better progress indicators
function automate_freebsd_install() {
    msg_info "Starting OPNsense installation from FreeBSD base"
    
    # Start VM if not running
    if ! qm status "$VMID" | grep -q "running"; then
        qm start "$VMID"
    fi
    
    # Wait for boot with progress indicator
    msg_info "Waiting for FreeBSD to boot"
    for i in {1..18}; do
        echo -n "."
        sleep 5
    done
    echo
    
    # Login as root (no password on fresh FreeBSD)
    send_line_to_vm "root"
    sleep 2

    # Download the OPNsense bootstrap script
    msg_info "Downloading OPNsense bootstrap script"
    send_line_to_vm "fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"
    sleep 10
    
    # Run the bootstrap script with recent version
    msg_info "Running OPNsense bootstrap (this will take 15-20 minutes)"
    send_line_to_vm "sh ./opnsense-bootstrap.sh.in -y -f -r 25.7"
    
    # This takes a long time - inform the user with progress indicator
    msg_ok "OPNsense bootstrap started. This will take 15-20 minutes to complete."
    echo "Please be patient. The system will automatically configure OPNsense."
    echo "Do not interrupt this process!"
    
    # Wait for installation to complete with progress indicator
    for i in {1..180}; do
        echo -n "."
        sleep 5
    done
    echo
    
    # Stop VM after installation
    msg_info "Installation should be complete. Stopping VM to finalize configuration"
    qm stop "$VMID"
    
    # Wait for VM to stop
    until qm status "$VMID" | grep -q "stopped"; do
        sleep 2
    done
    
    msg_ok "OPNsense installation from FreeBSD base complete"
    msg_info "Starting VM for final configuration"
    
    # Start VM again
    qm start "$VMID"
    sleep 90
    
    # Login with default credentials
    send_line_to_vm "root"
    send_line_to_vm "opnsense"
    sleep 2
    send_line_to_vm "2"
    sleep 2

    # Configure LAN interface
    if [ -n "${IP_ADDR:-}" ]; then
        send_line_to_vm "1"
        send_line_to_vm "n"
        send_line_to_vm "${IP_ADDR}"
        send_line_to_vm "${NETMASK:-24}"
        send_line_to_vm "${LAN_GW:-}"
        send_line_to_vm "n"
        send_line_to_vm " "
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm " "
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm "n"
    else
        send_line_to_vm "1"
        send_line_to_vm "y"
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm " "
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm "n"
    fi

    # Wait for config changes to be saved
    sleep 20

    # Configure WAN interface if dual-interface mode
    if [ -n "${BRIDGE2:-}" ] && [ -n "${WAN_IP_ADDR:-}" ]; then
        send_line_to_vm "2"
        send_line_to_vm "2"
        send_line_to_vm "n"
        send_line_to_vm "${WAN_IP_ADDR}"
        send_line_to_vm "${WAN_NETMASK:-24}"
        send_line_to_vm "${WAN_GW:-}"
        send_line_to_vm "n"
        send_line_to_vm " "
        send_line_to_vm "n"
        send_line_to_vm " "
        send_line_to_vm "n"
        send_line_to_vm "n"
        send_line_to_vm "n"
    fi

    sleep 10
    send_line_to_vm "0"

    msg_ok "OPNsense FreeBSD installation completed and configured"
}

function prompt_mount_config() {
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "MOUNT CONFIGURATION" \
        --yesno "Would you like to mount an OPNsense XML configuration file to the VM?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        msg_info "Root password will be needed for the configuration"
        prompt_root_password
        
        # Check if external config script exists
        local config_script="$(dirname "$0")/opncfgiso.sh"
        if [ -f "$config_script" ] && [ -x "$config_script" ]; then
            msg_info "Found external configuration script: $config_script"
            
            # Prompt for config.xml path
            local CONFIG_XML_PATH=""
            while true; do
                CONFIG_XML_PATH=$(whiptail \
                    --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter the full path to your config.xml file:" \
                    10 60 \
                    --title "CONFIG.XML PATH" \
                    --cancel-button "Exit Script" \
                    3>&1 1>&2 2<&3) || exit_script

                if [[ -f "$CONFIG_XML_PATH" ]]; then
                    msg_ok "Config.xml found at '$CONFIG_XML_PATH'"
                    break
                else
                    msg_error "File not found at '$CONFIG_XML_PATH'. Please try again."
                fi
            done
            
            # Use the external script
            msg_info "Using external script to create configuration ISO"
            if ! bash "$config_script" -vmid "$VMID" -cfgxml "$CONFIG_XML_PATH" -storage "$ISO_STORAGE"; then
                msg_error "Failed to create configuration ISO with external script"
                exit 1
            fi
            
            msg_ok "Configuration ISO created and attached with external script"
        else
            # Use internal function
            msg_info "Using built-in function to create configuration ISO"
            interactive_mount_config
        fi
        
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "AUTOMATE CONFIG IMPORT" \
            --yesno "Would you like the script to automatically import the configuration?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
            msg_info "Proceeding to automate configuration import"
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
    VM_ID="$VMID"
    CONFIG_STORAGE=""

    # Prompt for config.xml file
    while true; do
        CONFIG_XML_PATH=$(whiptail \
            --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter the full path to your config.xml file:" \
            10 60 \
            --title "CONFIG.XML PATH" \
            --cancel-button "Exit Script" \
            3>&1 1>&2 2<&3) || exit_script

        if [[ -f "$CONFIG_XML_PATH" ]]; then
            msg_ok "Config.xml found at '$CONFIG_XML_PATH'"
            break
        else
            msg_error "File not found at '$CONFIG_XML_PATH'. Please try again."
        fi
    done

    # Ask which storage to use for the configuration ISO
    CONFIG_STORAGE=$(select_config_storage "Configuration Storage Location" "Which storage pool should the config image be created in?")

    # Create and attach the configuration ISO
    create_and_attach_config
}

function process_config_passwords() {
    local config_file="$1"
    
    # Check if xmlstarlet is available
    if command -v xmlstarlet &>/dev/null; then
        msg_info "Using xmlstarlet to clear password fields"
        if ! xmlstarlet ed -L \
            -u "//user/password" -v "" \
            "$config_file"; then
            msg_error "Failed to clear password fields with xmlstarlet"
            return 1
        fi
        msg_ok "Password fields cleared with xmlstarlet"
        return 0
    fi
    
    # Fallback method using sed if xmlstarlet is not available
    msg_warn "Using fallback method to clear password fields (less precise than xmlstarlet)"
    
    # Create a backup of the original file
    cp "$config_file" "${config_file}.bak"
    
    # Use sed to try to clear password fields
    if ! sed -i -E 's|(<password>).*?(</password>)|\1\2|g' "$config_file"; then
        msg_error "Failed to clear password fields with fallback method"
        # Restore from backup
        mv "${config_file}.bak" "$config_file"
        return 1
    fi
    
    # Clean up backup
    rm -f "${config_file}.bak"
    
    msg_ok "Password fields cleared with fallback method"
    return 0
}

function create_and_attach_config() {
    local CONFIG_LABEL="CONFIG"
    local iso_name="opnconfig-${VMID}.iso"
    local work_dir=$(mktemp -d)
    
    msg_info "Creating temporary work directory"
    
    # Create the directory structure
    mkdir -p "${work_dir}/conf"
    
    # Copy the config file
    msg_info "Copying config.xml to temporary location"
    if ! cp "${CONFIG_XML_PATH}" "${work_dir}/conf/config.xml"; then
        msg_error "Failed to copy config file"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Process passwords
    msg_info "Processing user passwords in configuration"
    if ! process_config_passwords "${work_dir}/conf/config.xml"; then
        msg_warn "Password processing completed with warnings. The configuration might contain sensitive data."
        
        # Ask user to continue
        local continue_anyway=""
        read -rp "Continue anyway? (y/n): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            msg_info "Aborting at user request"
            rm -rf "${work_dir}"
            exit 1
        fi
    else
        msg_ok "Password processing completed successfully"
    fi

    # Verify the file was copied correctly
    if ! [ -f "${work_dir}/conf/config.xml" ]; then
        msg_error "Config file not found in expected location after copy"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Create the ISO
    msg_info "Creating configuration ISO"
    if ! genisoimage -quiet -o "${work_dir}/${iso_name}" -V "${CONFIG_LABEL}" -r -J "${work_dir}"; then
        msg_error "Failed to create config image"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Verify ISO was created
    if ! [ -f "${work_dir}/${iso_name}" ]; then
        msg_error "ISO file not found after creation"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Move ISO to storage
    local iso_storage_path
    if [ "$ISO_STORAGE" = "local" ]; then
        iso_storage_path="/var/lib/vz/template/iso"
    else
        iso_storage_path="$(pvesm path "$ISO_STORAGE")/template/iso"
    fi
    
    msg_info "Moving ISO to storage location"
    mkdir -p "$iso_storage_path"
    
    if ! mv "${work_dir}/${iso_name}" "${iso_storage_path}/${iso_name}"; then
        msg_error "Failed to move config image to storage"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Verify ISO exists in final location
    if ! [ -f "${iso_storage_path}/${iso_name}" ]; then
        msg_error "ISO file not found in final location"
        rm -rf "${work_dir}"
        exit 1
    fi

    # Clean up work directory
    rm -rf "${work_dir}"

    # Check if VM already has a device on ide2
    if qm config "$VMID" | grep -q "ide2:"; then
        msg_info "Removing existing device on ide2"
        if ! qm set "$VMID" -delete ide2; then
            msg_error "Failed to remove existing device on ide2"
            exit 1
        fi
    fi

    # Attach the ISO to the VM as ide2
    msg_info "Attaching configuration ISO to VM"
    if ! qm set "${VMID}" --ide2 "${ISO_STORAGE}:iso/${iso_name},media=cdrom"; then
        msg_error "Failed to attach config image to VM"
        rm -f "${iso_storage_path}/${iso_name}"
        exit 1
    fi

    msg_ok "Config image created and attached as ide2"
}

# Enhanced config import with better timing
function automate_config_import() {
        msg_info "Starting VM"
        qm status "$VMID" | grep -q "running" || qm start "$VMID"
        
        # Wait for initial boot with progress indicator
        msg_info "Waiting for VM to boot"
        for i in {1..30}; do
            echo -n "."
            sleep 5
        done
        echo
        
        msg_info "VM booted, sending installer command"
        # Start the installer
        send_line_to_vm "installer"
        send_line_to_vm "opnsense"
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
        sleep 2
        qm sendkey $VMID down
        press_enter
        # Confirm swap
        sleep 10
        press_enter
        # Confirm destroy
        sleep 5
        qm sendkey $VMID left
        press_enter

        # Wait for installation with progress indicator
        msg_info "Installing OPNsense"
        for i in {1..66}; do
            echo -n "."
            sleep 5
        done
        echo

        # Set root password
        press_enter
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        # Confirm reboot
        sleep 20
        qm sendkey $VMID down
        press_enter
        # Wait for reboot
        sleep 30
        # Stop the VM
        msg_info "Stopping VM"
        qm status "$VMID" | grep -q "stopped" || qm stop "$VMID"
        # Wait for stop
        until qm status $VMID | grep -q "stopped"; do
            sleep 2
        done
        # Remove CD boot device
        qm set $VMID -delete ide3
        qm set $VMID -boot c -bootdisk scsi0
        # Start the VM
        msg_info "Starting VM for configuration"
        qm status "$VMID" | grep -q "running" || qm start "$VMID"
        sleep 80
        # Login as root
        send_line_to_vm "root"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        # Import Config from Mounted ISO
        sleep 4
        send_line_to_vm "8"
        sleep 2
        send_line_to_vm "opnsense-importer"
        sleep 2
        send_line_to_vm "cd0"
        sleep 2
        # After successful import, cleanup and restart
        sleep 25
        send_line_to_vm "exit"
        sleep 2
        # Set root password again
        send_line_to_vm "3"
        sleep 2
        send_line_to_vm "y"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        send_line_to_vm "$ROOT_PASSWORD"
        sleep 2
        # Reboot VM
        send_line_to_vm "6"
        sleep 2
        send_line_to_vm "Y"
        sleep 150
        # Force remove ISO from mount list
        msg_info "Stopping VM for cleanup"
        qm status "$VMID" | grep -q "stopped" || qm stop "$VMID"
        until qm status $VMID | grep -q "stopped"; do
        sleep 2
        done
        # Remove the mounted ISO and delete the ISO file
        msg_info "Cleaning up configuration ISO"
        qm set $VMID -delete ide2
        # Delete the actual ISO file
        local iso_name="opnconfig-${VMID}.iso"
        local iso_path
        if [ "$ISO_STORAGE" = "local" ]; then
            iso_path="/var/lib/vz/template/iso/${iso_name}"
        else
            iso_path="$(pvesm path "$ISO_STORAGE")/template/iso/${iso_name}"
        fi
        if [ -f "$iso_path" ]; then
            msg_info "Removing configuration ISO file"
            rm -f "$iso_path"
            msg_ok "Configuration ISO removed"
        fi
        # Start the VM again
        msg_info "Starting VM after configuration import"
        qm status "$VMID" | grep -q "running" || qm start "$VMID"
        sleep 40
        # Config Import completed
        msg_ok "Configuration import and cleanup completed"
}

function add_host_network_interfaces() {
    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --title "ADD INTERFACES" --defaultno \
            --yesno "Would you like to add the interfaces to /etc/network/interfaces?" \
            10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then

            msg_info "Listing physical interfaces"
            PHYSICAL_INTERFACES=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo)
            echo "Available physical interfaces:"
            echo "$PHYSICAL_INTERFACES"

            BRIDGE_PORT_LAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                --inputbox "Enter bridge-ports for $BRIDGE1 (LAN)" 8 60 --title "BRIDGE-PORTS (LAN)" \
                --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

            # LAN bridge
            if grep -q "^iface $BRIDGE1" /etc/network/interfaces; then
                msg_warn "Bridge $BRIDGE1 already exists in /etc/network/interfaces"
                if ! (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --title "BRIDGE EXISTS" \
                    --yesno "Bridge $BRIDGE1 already exists. Overwrite configuration?" \
                    10 60 --yes-button "Overwrite" --no-button "Skip"); then
                    msg_info "Skipping $BRIDGE1 configuration"
                else
                    sed -i "/^auto $BRIDGE1/,/^$/d" /etc/network/interfaces
                    echo -e "\nauto $BRIDGE1\niface $BRIDGE1 inet manual\n\tbridge-ports $BRIDGE_PORT_LAN\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                    msg_ok "Updated $BRIDGE1 configuration"
                fi
            else
                echo -e "\nauto $BRIDGE1\niface $BRIDGE1 inet manual\n\tbridge-ports $BRIDGE_PORT_LAN\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                msg_ok "Added $BRIDGE1 configuration"
            fi

            # WAN bridge (only if dual-interface mode)
            if [ -n "${BRIDGE2:-}" ]; then
                BRIDGE_PORT_WAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter bridge-ports for $BRIDGE2 (WAN)" 8 60 --title "BRIDGE-PORTS (WAN)" \
                    --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

                if grep -q "^iface $BRIDGE2" /etc/network/interfaces; then
                    msg_warn "Bridge $BRIDGE2 already exists in /etc/network/interfaces"
                    if ! (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                        --title "BRIDGE EXISTS" \
                        --yesno "Bridge $BRIDGE2 already exists. Overwrite configuration?" \
                        10 60 --yes-button "Overwrite" --no-button "Skip"); then
                        msg_info "Skipping $BRIDGE2 configuration"
                    else
                        sed -i "/^auto $BRIDGE2/,/^$/d" /etc/network/interfaces
                        echo -e "\nauto $BRIDGE2\niface $BRIDGE2 inet manual\n\tbridge-ports $BRIDGE_PORT_WAN\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                        msg_ok "Updated $BRIDGE2 configuration"
                    fi
                else
                    echo -e "\nauto $BRIDGE2\niface $BRIDGE2 inet manual\n\tbridge-ports $BRIDGE_PORT_WAN\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                    msg_ok "Added $BRIDGE2 configuration"
                fi
            fi

            # MGMT bridge (only if configured)
            if [ -n "${BRIDGE3:-}" ]; then
                BRIDGE_PORT_MGMT=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter bridge-ports for $BRIDGE3 (MGMT)" 8 60 --title "BRIDGE-PORTS (MGMT)" \
                    --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

                MGMT_IP=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter static IP address for $BRIDGE3 (MGMT)" 8 60 --title "MGMT IP (MGMT)" \
                    --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

                MGMT_GW=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter gateway for $BRIDGE3 (MGMT)" 8 60 --title "MGMT GATEWAY (MGMT)" \
                    --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

                MGMT_SUBNET=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --inputbox "Enter subnet mask for $BRIDGE3 (MGMT) (CIDR format, e.g., 24)" 8 60 "24" \
                    --title "MGMT SUBNET (MGMT)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

                if grep -q "^iface $BRIDGE3" /etc/network/interfaces; then
                    msg_warn "Bridge $BRIDGE3 already exists in /etc/network/interfaces"
                    if ! (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                        --title "BRIDGE EXISTS" \
                        --yesno "Bridge $BRIDGE3 already exists. Overwrite configuration?" \
                        10 60 --yes-button "Overwrite" --no-button "Skip"); then
                        msg_info "Skipping $BRIDGE3 configuration"
                    else
                        sed -i "/^auto $BRIDGE3/,/^$/d" /etc/network/interfaces
                        echo -e "\nauto $BRIDGE3\niface $BRIDGE3 inet static\n\taddress $MGMT_IP/$MGMT_SUBNET\n\tgateway $MGMT_GW\n\tbridge-ports $BRIDGE_PORT_MGMT\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                        msg_ok "Updated $BRIDGE3 configuration"
                    fi
                else
                    echo -e "\nauto $BRIDGE3\niface $BRIDGE3 inet static\n\taddress $MGMT_IP/$MGMT_SUBNET\n\tgateway $MGMT_GW\n\tbridge-ports $BRIDGE_PORT_MGMT\n\tbridge-stp off\n\tbridge-fd 0" >> /etc/network/interfaces
                    msg_ok "Added $BRIDGE3 configuration"
                fi
            fi

            msg_ok "Interfaces added to /etc/network/interfaces"
            echo "Note: You may need to restart networking or reboot for changes to take effect:"
            echo "  systemctl restart networking"
        fi
    fi
}

#################################################################################
# Main Script Execution                                                          #
#################################################################################

header_info

# Check prerequisites
check_root
check_dependencies
arch_check
pve_check
ssh_check

# Create a temporary directory for downloads
TEMP_DIR=$(mktemp -d)
trap cleanup EXIT

# Prompt user to proceed
if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "OPNsense VM" \
    --yesno "This will create a New OPNsense VM. Proceed?" 10 58 \
    --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
    header_info && echo -e "⚠ User exited script.\n" && exit 1
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

# Prompt to select installation method
if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
    --title "INSTALLATION METHOD" \
    --yesno "Use ISO installation method? (Recommended)\nNo = Use FreeBSD base installation method" \
    10 60 --yes-button "Use ISO" --no-button "Use FreeBSD" --cancel-button "Exit Script"; then
    INSTALLATION_METHOD="freebsd"
    msg_ok "Using FreeBSD base installation method"
else
    INSTALLATION_METHOD="iso"
    msg_ok "Using ISO installation method"
fi

# Gather user-defined settings
start_script

# Now pick separate storages for ISO vs. VM disks:
ISO_STORAGE=$(select_iso_storage)
VM_STORAGE=$(select_disk_storage)
msg_ok "Selected [$ISO_STORAGE] for ISO and [$VM_STORAGE] for VM Disks"

# Verify bridges exist if managing interfaces
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    verify_bridge_exists "$BRIDGE1" "LAN"
    if [ -n "${BRIDGE2:-}" ]; then
        verify_bridge_exists "$BRIDGE2" "WAN"
    fi
    if [ -n "${BRIDGE3:-}" ]; then
        verify_bridge_exists "$BRIDGE3" "MGMT"
    fi
fi

# Handle installation media based on method
if [ "$INSTALLATION_METHOD" = "iso" ]; then
    # Next pick the ISO (local or downloaded)
    select_iso
else
    # Handle FreeBSD image download
    handle_freebsd_download
fi

# Create the VM with all enhancements
create_vm

# Optional config mount or automated setup
if [ "$INSTALLATION_METHOD" = "iso" ]; then
    prompt_mount_config
fi

# Start if user asked:
if [ "$START_VM" = "yes" ]; then
    if [ "$INSTALLATION_METHOD" = "iso" ]; then
        if [ "$AUTOMATE_SETUP" = "yes" ]; then
            msg_info "Starting OPNsense VM"
            qm status "$VMID" | grep -q "running" || qm start "$VMID"
            msg_info "VM Started. Proceeding to automate the installation."
            automate_install
        else
            msg_info "Starting OPNsense VM"
            qm status "$VMID" | grep -q "running" || qm start "$VMID"
            msg_ok "VM started."
        fi
    else
        # FreeBSD method
        msg_info "Starting OPNsense installation from FreeBSD base"
        automate_freebsd_install
    fi
else
    msg_info "VM creation complete. VM not started."
fi

# If also bridging on host
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    add_host_network_interfaces
fi

# Display completion message with enhanced info
msg_ok "Completed Successfully!"
echo

# Display access information
if [ -n "${IP_ADDR:-${LAN_IPV4:-}}" ]; then
    local_ip="${IP_ADDR:-${LAN_IPV4:-}}"
    echo -e "${INFO} ${BL}Access Information:${CL}"
    echo -e "${TAB}${YL}Web Interface:${CL}"
    if [ "${ENABLE_HTTPS:-}" = "y" ]; then
        echo -e "${TAB}  ${GN}https://${local_ip}/${CL}"
    else
        echo -e "${TAB}  ${GN}http://${local_ip}/${CL}"
    fi
    echo -e "${TAB}${YL}Username:${CL} ${GN}root${CL}"
    echo -e "${TAB}${YL}Password:${CL} ${GN}[your configured password]${CL}"
else
    echo -e "${INFO} ${YL}The OPNsense VM has been created.${CL}"
    echo -e "${INFO} ${YL}LAN IP was DHCP.${CL}"
    echo -e "${TAB}${INFO} ${BGN}To find the IP login to the VM shell${CL}"
    echo -e "${TAB}${YL}Default username:${CL} ${GN}root${CL}"
    echo -e "${TAB}${YL}Default password:${CL} ${GN}opnsense${CL} (if not changed during setup)"
fi

# Additional information
echo
echo -e "${INFO} ${BL}VM Information:${CL}"
echo -e "${TAB}${YL}VM ID:${CL} ${GN}$VMID${CL}"
echo -e "${TAB}${YL}Hostname:${CL} ${GN}$HN${CL}"
echo -e "${TAB}${YL}Installation Method:${CL} ${GN}$INSTALLATION_METHOD${CL}"

if [ "$SERIAL_CONSOLE" = "yes" ]; then
    echo -e "${TAB}${YL}Serial Console:${CL} ${GN}Enabled (qm terminal $VMID)${CL}"
fi

# Network information if interfaces were managed
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    echo
    echo -e "${INFO} ${BL}Network Configuration:${CL}"
    echo -e "${TAB}${YL}LAN:${CL} Bridge ${GN}$BRIDGE1${CL} (MAC: ${GN}$MAC1${CL})"
    if [ -n "${VLAN1:-}" ]; then echo -e "${TAB}      VLAN: ${GN}$VLAN1${CL}"; fi
    if [ -n "${BRIDGE2:-}" ]; then
        echo -e "${TAB}${YL}WAN:${CL} Bridge ${GN}$BRIDGE2${CL} (MAC: ${GN}$MAC2${CL})"
        if [ -n "${VLAN2:-}" ]; then echo -e "${TAB}      VLAN: ${GN}$VLAN2${CL}"; fi
    fi
    if [ -n "${BRIDGE3:-}" ]; then
        echo -e "${TAB}${YL}MGMT:${CL} Bridge ${GN}$BRIDGE3${CL} (MAC: ${GN}$MAC3${CL})"
        if [ -n "${VLAN3:-}" ]; then echo -e "${TAB}      VLAN: ${GN}$VLAN3${CL}"; fi
    fi
fi

echo
exit 0
