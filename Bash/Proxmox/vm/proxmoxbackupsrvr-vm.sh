#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# Purpose: Automate the creation of a Proxmox Backup Server (PBS) VM in Proxmox VE
# Parses enterprise.proxmox.com/iso/ for available PBS ISOs, verifies SHA256 against
# the published SHA256SUMS manifest, and creates a UEFI VM ready for PBS installation.
#
# Usage:
#   proxmoxbackupsrvr-vm.sh              # interactive
#   proxmoxbackupsrvr-vm.sh --defaults   # non-interactive with sensible defaults
#   proxmoxbackupsrvr-vm.sh --help       # show usage
#
# Dependencies: whiptail, wget, curl, openssl, numfmt, awk, sed,
#               Proxmox CLI tools (qm, pvesm, pvesh, pveversion)

set -Eeuo pipefail

#################################################################################
# Configuration Settings                                                         #
#################################################################################

# Repository and fallback (current PBS stable: 4.1-1 published 2025-11-26)
PBS_DOWNLOAD_DIR="https://enterprise.proxmox.com/iso/"
SHA256SUMS_URL="${PBS_DOWNLOAD_DIR}SHA256SUMS"
FALLBACK_VERSION="4.1-1"
FALLBACK_DATE="2025-11-26"
FALLBACK_ISO="proxmox-backup-server_${FALLBACK_VERSION}.iso"
FALLBACK_URL="${PBS_DOWNLOAD_DIR}${FALLBACK_ISO}"
FALLBACK_SHA256="670f0a71ee25e00cc7839bebb3f399594f5257e49a224a91ce517460e7ab171e"

# VM ID range
STARTING_VM_ID=300
NEXTID=$STARTING_VM_ID

# Default network settings
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MTU="1500"

# CLI flags
NON_INTERACTIVE="no"

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

function msg_info()  { echo -ne " ${HOLD} ${YL}${1}...${CL}"; }
function msg_ok()    { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
function msg_warn()  { echo -e "${BFR} ${WARN} ${YL}Warning:${CL} $1"; }
function msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

#################################################################################
# ASCII Art                                                                      #
#################################################################################

function header_info() {
    clear
    cat <<"EOF"
  ____                                 ____             _
 |  _ \ _ __ _____  ___ __ ___   _____| __ )  __ _  ___| | ___   _ _ __
 | |_) | '__/ _ \ \/ / '_ ` _ \ / _ \_\ _ \ / _` |/ __| |/ / | | | '_ \
 |  __/| | | (_) >  <| | | | | | (_) |_) | (_| | (__|   <| |_| | |_) |
 |_|   |_|  \___/_/\_\_| |_| |_|\___(____/ \__,_|\___|_|\_\\__,_| .__/
                                                                |_|
          P R O X M O X   B A C K U P   S E R V E R   V M
EOF
}

#################################################################################
# Global State                                                                   #
#################################################################################

TEMP_DIR=""
VMID=""
MACHINE=""
CPU_TYPE=""
BRG=""
HN=""
DISK_CACHE=""
ISO_STORAGE=""
STORAGE=""
EFI_DISK_SIZE=""
VM_TAG=""
MTU=""
VLAN=""
DISK_SIZE=""
RAM_SIZE=""
CORE_COUNT=""
START_VM=""
QEMU_AGENT=""
BALLOON=""
PROTECTION=""
SERIAL_CONSOLE=""
MAC=""
ISO_PATH=""
ISO_BASENAME=""
ISO_EXPECTED_SHA=""
ISO_ENTRIES=()

#################################################################################
# Error Handling and Cleanup                                                     #
#################################################################################

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
    cleanup_vmid
    exit "$exit_code"
}

function cleanup_vmid() {
    if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
        local state
        state=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
        if [[ "$state" == "running" || "$state" == "stopped" ]]; then
            msg_info "Cleaning up VM $VMID"
            if [[ "$state" == "running" ]]; then
                qm stop "$VMID" &>/dev/null || true
            fi
            sleep 2
            qm destroy "$VMID" --purge 1 &>/dev/null || true
            msg_ok "Cleaned up partially-created VM $VMID"
        fi
    fi
}

function cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

function exit_script() {
    clear
    echo -e "User exited script.\n"
    exit 1
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'exit 130' SIGINT
trap 'exit 143' SIGTERM
trap 'exit 129' SIGHUP

#################################################################################
# CLI / Help                                                                     #
#################################################################################

function usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Create a Proxmox Backup Server VM in Proxmox VE with verified ISO.

Options:
  --defaults      Skip interactive prompts; use sensible defaults
  -h, --help      Show this help message

Environment:
  NEXTID override via VMID=<id>, bridge via BRG=<name> (only with --defaults)

Examples:
  $0                     Launch interactive wizard
  $0 --defaults          Create VM non-interactively
EOF
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --defaults)   NON_INTERACTIVE="yes"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            msg_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
}

#################################################################################
# Dependency Checking                                                            #
#################################################################################

function check_dependencies() {
    local deps=(whiptail pvesh pvesm qm wget curl openssl numfmt awk sed)
    declare -A cmd_pkg_map=(
        [whiptail]=whiptail
        [pvesh]=pve-manager
        [pvesm]=pve-manager
        [qm]=pve-manager
        [wget]=wget
        [curl]=curl
        [openssl]=openssl
        [numfmt]=coreutils
        [awk]=mawk
        [sed]=sed
    )

    local missing_pkgs=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("${cmd_pkg_map[$cmd]:-$cmd}")
        fi
    done

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        msg_ok "All required dependencies are installed"
        return 0
    fi

    # Deduplicate
    local uniq
    mapfile -t uniq < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)

    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        msg_info "Installing missing packages: ${uniq[*]}"
        apt-get update -qq
        apt-get install -y "${uniq[@]}"
        msg_ok "Dependencies installed"
        return 0
    fi

    msg_warn "Missing packages: ${uniq[*]}"
    local choice
    read -rp "Install them now via apt-get? (y/n): " choice
    case "$choice" in
        y|Y)
            msg_info "Updating package lists"
            apt-get update -qq || { msg_error "apt-get update failed"; exit 1; }
            msg_ok "Package lists updated"
            msg_info "Installing ${uniq[*]}"
            apt-get install -y "${uniq[@]}" || { msg_error "Install failed"; exit 1; }
            msg_ok "Dependencies installed"
            ;;
        *)
            msg_error "Required dependencies missing. Exiting."
            exit 1
            ;;
    esac
}

#################################################################################
# System Validation                                                              #
#################################################################################

function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        msg_error "This script must be run as root"
        echo -e "\nPlease run: sudo $0"
        exit 1
    fi
}

function arch_check() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if [[ "$arch" != "amd64" && "$arch" != "x86_64" ]]; then
        msg_error "PBS is only supported on amd64 (detected: $arch)"
        exit 1
    fi
}

function pve_check() {
    if ! command -v pveversion &>/dev/null; then
        msg_error "This script must be run on a Proxmox VE host"
        exit 1
    fi

    local pve_ver
    pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"

    if [[ "$pve_ver" =~ ^8\.([0-9]+) ]]; then
        local minor="${BASH_REMATCH[1]}"
        if ((minor < 1)); then
            msg_error "Proxmox VE $pve_ver is too old (need 8.1+)"
            exit 1
        fi
        msg_ok "Proxmox VE $pve_ver detected"
        return 0
    fi
    if [[ "$pve_ver" =~ ^9\.([0-9]+) ]]; then
        msg_ok "Proxmox VE $pve_ver detected"
        return 0
    fi

    msg_error "Unsupported Proxmox VE version: $pve_ver"
    msg_error "Supported: Proxmox VE 8.1+ or 9.x"
    exit 1
}

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" && "$NON_INTERACTIVE" != "yes" ]]; then
        if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's recommended to use the Proxmox shell instead of SSH.\nSSH can cause issues with interactive elements.\n\nContinue anyway?" 12 62; then
            exit_script
        fi
    fi
}

#################################################################################
# VM ID and Utility                                                              #
#################################################################################

function get_valid_nextid() {
    local try_id
    try_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "$STARTING_VM_ID")
    [[ "$try_id" -lt "$STARTING_VM_ID" ]] && try_id=$STARTING_VM_ID

    while true; do
        if [[ -f "/etc/pve/qemu-server/${try_id}.conf" ]]; then
            ((try_id++)); continue
        fi
        if [[ -f "/etc/pve/lxc/${try_id}.conf" ]]; then
            ((try_id++)); continue
        fi
        if command -v lvs &>/dev/null && \
           lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
            ((try_id++)); continue
        fi
        break
    done
    echo "$try_id"
}

function check_vmid() { NEXTID=$(get_valid_nextid); }

function generate_mac() {
    local hex
    if command -v openssl &>/dev/null; then
        hex=$(openssl rand -hex 5)
    else
        hex=$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')
    fi
    echo "02:$(echo "$hex" | sed 's/\(..\)/\1:/g; s/.$//' | tr '[:lower:]' '[:upper:]')"
}

function get_available_bridges() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort
}

function verify_bridge_exists() {
    local bridge="$1"

    if ip link show "$bridge" &>/dev/null; then
        msg_ok "Bridge '$bridge' exists"
        return 0
    fi

    msg_warn "Bridge '$bridge' does not exist"

    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        msg_error "Required bridge '$bridge' missing (non-interactive mode)"
        exit 1
    fi

    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "BRIDGE NOT FOUND" \
        --yesno "Bridge '$bridge' does not exist.\n\nCreate it now?" 10 60; then
        msg_info "Creating bridge $bridge"
        printf "\nauto %s\niface %s inet manual\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0\n" \
            "$bridge" "$bridge" >> /etc/network/interfaces
        if systemctl restart networking 2>/dev/null && ip link show "$bridge" &>/dev/null; then
            msg_ok "Bridge $bridge created"
        else
            msg_warn "Bridge configured but not yet active — a reboot may be required"
        fi
    else
        msg_error "Bridge '$bridge' is required. Please create it manually."
        exit 1
    fi
}

#################################################################################
# VM Configuration                                                               #
#################################################################################

function default_settings() {
    check_vmid
    VMID="${VMID:-$NEXTID}"
    MACHINE="q35"
    DISK_CACHE=""
    HN="PBS-VM${VMID}"
    CPU_TYPE="host"
    CORE_COUNT="4"
    RAM_SIZE="4096"
    DISK_SIZE="32G"
    BRG="${BRG:-$DEFAULT_BRIDGE}"
    MAC=$(generate_mac)
    VLAN=""
    MTU="$DEFAULT_MTU"
    START_VM="yes"
    VM_TAG="backup;pbs"
    EFI_DISK_SIZE="4M"
    SERIAL_CONSOLE="yes"
    QEMU_AGENT="yes"
    BALLOON="yes"
    PROTECTION="no"
    msg_ok "Default settings applied"
}

function advanced_settings() {
    check_vmid
    local bt="Proxmox VE PBS Install Script"

    VMID=$(whiptail --backtitle "$bt" \
        --inputbox "Virtual Machine ID (Default: $NEXTID)" 8 60 "$NEXTID" \
        --title "VM ID" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$VMID" =~ ^[0-9]+$ ]] || { msg_error "VM ID must be numeric"; exit 1; }

    HN=$(whiptail --backtitle "$bt" \
        --inputbox "Hostname" 8 60 "PBS-VM${VMID}" \
        --title "HOSTNAME" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    MACHINE=$(whiptail --backtitle "$bt" \
        --title "MACHINE TYPE" --radiolist "Select machine type:" 10 60 2 \
        "q35"    "Q35 (modern, PCIe) [recommended]" ON \
        "i440fx" "i440fx (legacy)" OFF \
        3>&1 1>&2 2>&3) || exit_script

    DISK_CACHE=$(whiptail --backtitle "$bt" \
        --title "DISK CACHE" --radiolist "Select disk cache mode:" 14 60 5 \
        ""             "Default / none (recommended)" ON \
        "writeback"    "Writeback (better perf)" OFF \
        "writethrough" "Writethrough (balanced)" OFF \
        "directsync"   "Direct sync (safest)" OFF \
        "unsafe"       "Unsafe (fastest, NOT for prod)" OFF \
        3>&1 1>&2 2>&3) || exit_script

    CPU_TYPE=$(whiptail --backtitle "$bt" \
        --title "CPU MODEL" --radiolist "Select CPU model:" 12 60 4 \
        "host"   "Host (best performance)" ON \
        "x86-64-v2-AES" "Modern baseline" OFF \
        "kvm64"  "KVM64 (compatibility)" OFF \
        "max"    "Maximum features" OFF \
        3>&1 1>&2 2>&3) || exit_script

    CORE_COUNT=$(whiptail --backtitle "$bt" \
        --inputbox "CPU cores" 8 60 "4" \
        --title "CPU CORES" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$CORE_COUNT" =~ ^[0-9]+$ ]] || { msg_error "Cores must be numeric"; exit 1; }

    RAM_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "RAM size in MiB" 8 60 "4096" \
        --title "RAM" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$RAM_SIZE" =~ ^[0-9]+$ ]] || { msg_error "RAM must be numeric"; exit 1; }

    DISK_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "OS disk size (e.g. 32G)" 8 60 "32G" \
        --title "DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    # Offer a list of existing bridges
    local bridges
    mapfile -t bridges < <(get_available_bridges)
    if ((${#bridges[@]} > 0)); then
        local br_items=()
        for b in "${bridges[@]}"; do
            br_items+=("$b" "existing bridge")
        done
        br_items+=("__custom__" "Enter a different name")
        BRG=$(whiptail --backtitle "$bt" --title "NETWORK BRIDGE" \
            --menu "Select bridge (default: $DEFAULT_BRIDGE)" 18 60 10 \
            "${br_items[@]}" 3>&1 1>&2 2>&3) || exit_script
        if [[ "$BRG" == "__custom__" ]]; then
            BRG=$(whiptail --backtitle "$bt" \
                --inputbox "Bridge name" 8 60 "$DEFAULT_BRIDGE" \
                --title "BRIDGE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
        fi
    else
        BRG=$(whiptail --backtitle "$bt" \
            --inputbox "Bridge name" 8 60 "$DEFAULT_BRIDGE" \
            --title "BRIDGE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    fi

    MAC=$(whiptail --backtitle "$bt" \
        --inputbox "MAC address (auto)" 8 60 "$(generate_mac)" \
        --title "MAC" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    VLAN=$(whiptail --backtitle "$bt" \
        --inputbox "VLAN tag (blank = none)" 8 60 "" \
        --title "VLAN" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    MTU=$(whiptail --backtitle "$bt" \
        --inputbox "Interface MTU" 8 60 "$DEFAULT_MTU" \
        --title "MTU" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    VM_TAG=$(whiptail --backtitle "$bt" \
        --inputbox "VM tags (semicolon-separated)" 8 60 "backup;pbs" \
        --title "VM TAGS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    EFI_DISK_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "EFI disk size (4M is standard)" 8 60 "4M" \
        --title "EFI DISK" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    whiptail --backtitle "$bt" --title "SERIAL CONSOLE" \
        --yesno "Enable serial console?" 8 60 && SERIAL_CONSOLE="yes" || SERIAL_CONSOLE="no"
    whiptail --backtitle "$bt" --title "QEMU AGENT" \
        --yesno "Enable QEMU Guest Agent?" 8 60 && QEMU_AGENT="yes" || QEMU_AGENT="no"
    whiptail --backtitle "$bt" --title "BALLOONING" \
        --yesno "Enable memory ballooning?" 8 60 && BALLOON="yes" || BALLOON="no"
    whiptail --backtitle "$bt" --title "PROTECTION" \
        --defaultno --yesno "Enable VM protection (prevent accidental destroy)?" 8 60 \
        && PROTECTION="yes" || PROTECTION="no"
    whiptail --backtitle "$bt" --title "START VM" \
        --yesno "Start the VM after creation?" 8 60 && START_VM="yes" || START_VM="no"

    msg_ok "Advanced settings configured"
}

function start_script() {
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        default_settings
        return
    fi
    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "SETTINGS" \
        --yesno "Use default settings?\n\n(Select No to configure advanced options)" \
        --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

#################################################################################
# ISO Handling (discovery, download, checksum)                                   #
#################################################################################

function parse_iso_listing() {
    local html="$1"
    ISO_ENTRIES=()

    # Walk each href="proxmox-backup-server_X.Y-Z.iso" occurrence with its date
    # Listing lines look like:
    # <a href="proxmox-backup-server_4.1-1.iso">proxmox-backup-server_4.1-1.iso</a>   26-Nov-2025 12:34   1.5G
    while IFS= read -r line; do
        [[ "$line" =~ href=\"(proxmox-backup-server_[0-9]+\.[0-9]+-[0-9]+\.iso)\" ]] || continue
        local iso_file="${BASH_REMATCH[1]}"

        # Extract date — DD-Mon-YYYY
        local date_part
        date_part=$(echo "$line" | grep -oE '[0-9]{2}-[A-Za-z]{3}-[0-9]{4}' | head -1)
        [[ -z "$date_part" ]] && date_part="01-Jan-1970"

        # Convert to YYYY-MM-DD (portable month lookup)
        local dd mon yyyy mm
        dd=$(echo "$date_part" | cut -d'-' -f1)
        mon=$(echo "$date_part" | cut -d'-' -f2)
        yyyy=$(echo "$date_part" | cut -d'-' -f3)
        case "$mon" in
            Jan) mm=01 ;; Feb) mm=02 ;; Mar) mm=03 ;; Apr) mm=04 ;;
            May) mm=05 ;; Jun) mm=06 ;; Jul) mm=07 ;; Aug) mm=08 ;;
            Sep) mm=09 ;; Oct) mm=10 ;; Nov) mm=11 ;; Dec) mm=12 ;;
            *) mm=01 ;;
        esac
        local iso_date="${yyyy}-${mm}-${dd}"
        local iso_url="${PBS_DOWNLOAD_DIR}${iso_file}"
        ISO_ENTRIES+=("${iso_date}|${iso_file}|${iso_url}")
    done <<< "$html"

    # Sort newest first
    if ((${#ISO_ENTRIES[@]} > 0)); then
        mapfile -t ISO_ENTRIES < <(printf '%s\n' "${ISO_ENTRIES[@]}" | sort -r)
    fi
}

function fetch_sha256sums() {
    local sha_file="$1"
    msg_info "Fetching published SHA256SUMS"
    if curl -fsSL --connect-timeout 10 "$SHA256SUMS_URL" -o "$sha_file" 2>/dev/null; then
        msg_ok "SHA256SUMS fetched"
        return 0
    fi
    msg_warn "Could not fetch SHA256SUMS — checksum verification will be skipped"
    return 1
}

function sha_for_iso() {
    local iso_file="$1"
    local sha_file="$2"
    [[ -f "$sha_file" ]] || return 1
    awk -v f="$iso_file" '$2==f {print $1; exit}' "$sha_file"
}

function select_iso() {
    msg_info "Fetching available PBS ISOs from $PBS_DOWNLOAD_DIR"
    local html
    if html=$(curl -fsSL --connect-timeout 10 "$PBS_DOWNLOAD_DIR" 2>/dev/null); then
        parse_iso_listing "$html"
        msg_ok "Discovered ${#ISO_ENTRIES[@]} PBS ISO(s) upstream"
    else
        msg_warn "Could not reach $PBS_DOWNLOAD_DIR — will use fallback"
    fi

    # Always guarantee fallback is present if upstream empty
    if ((${#ISO_ENTRIES[@]} == 0)); then
        ISO_ENTRIES+=("${FALLBACK_DATE}|${FALLBACK_ISO}|${FALLBACK_URL}")
    fi

    # Fetch SHA256SUMS once
    local sha_file="${TEMP_DIR}/SHA256SUMS"
    fetch_sha256sums "$sha_file" || true

    # Prompt user: download or pick local?
    local use_local="no"
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        use_local="no"
    elif ! whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "ISO SOURCE" \
        --yesno "Download a PBS ISO from the official repository?\n\nChoose 'No' to pick from existing ISOs on this host." 10 70; then
        use_local="yes"
    fi

    if [[ "$use_local" == "yes" ]]; then
        select_local_iso
        return
    fi

    # Select ISO (non-interactive picks newest)
    local chosen_url chosen_file chosen_date
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        IFS='|' read -r chosen_date chosen_file chosen_url <<< "${ISO_ENTRIES[0]}"
    else
        local menu_items=()
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r d f u <<< "$entry"
            menu_items+=("$u" "$f  (${d})")
        done
        chosen_url=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "Available PBS ISOs" \
            --menu "Select an ISO to download:" 20 100 10 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
        for entry in "${ISO_ENTRIES[@]}"; do
            IFS='|' read -r d f u <<< "$entry"
            [[ "$u" == "$chosen_url" ]] && { chosen_file="$f"; chosen_date="$d"; break; }
        done
    fi

    ISO_BASENAME="$chosen_file"
    ISO_EXPECTED_SHA=$(sha_for_iso "$chosen_file" "$sha_file" || true)
    if [[ "$chosen_url" == "$FALLBACK_URL" && -z "$ISO_EXPECTED_SHA" ]]; then
        ISO_EXPECTED_SHA="$FALLBACK_SHA256"
    fi

    download_iso "$chosen_url" "$chosen_file"
}

function select_iso_storage() {
    # Where to store the ISO file — content type 'iso'
    local menu_items=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag stype free
        tag=$(echo "$line" | awk '{print $1}')
        stype=$(echo "$line" | awk '{print $2}')
        free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf "%9sB", $6}')
        [[ -z "$tag" ]] && continue
        menu_items+=("$tag" "Type: $stype, Free: $free")
    done < <(pvesm status -content iso 2>/dev/null)

    if ((${#menu_items[@]} == 0)); then
        msg_warn "No storage configured with 'iso' content — falling back to /var/lib/vz/template/iso"
        ISO_STORAGE="local"
        return
    fi

    # Auto-pick if only one option, or in non-interactive
    if ((${#menu_items[@]} == 2)) || [[ "$NON_INTERACTIVE" == "yes" ]]; then
        ISO_STORAGE="${menu_items[0]}"
        msg_ok "Using ISO storage: $ISO_STORAGE"
        return
    fi

    ISO_STORAGE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "ISO STORAGE" \
        --menu "Select storage for the PBS ISO:" 18 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using ISO storage: $ISO_STORAGE"
}

function iso_storage_path() {
    # Resolve the filesystem path for an ISO storage pool
    local stg="$1"
    local path
    path=$(pvesm path "${stg}:iso/_" 2>/dev/null | sed 's|/_$||' || true)
    if [[ -z "$path" ]]; then
        path="/var/lib/vz/template/iso"
    fi
    mkdir -p "$path"
    echo "$path"
}

function verify_iso_checksum() {
    local file="$1"
    local expected="$2"
    [[ -z "$expected" ]] && { msg_warn "No checksum available — skipping verification"; return 0; }
    msg_info "Verifying SHA256 checksum"
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [[ "$actual" == "$expected" ]]; then
        msg_ok "SHA256 verified: ${actual:0:16}…"
        return 0
    fi
    msg_error "SHA256 mismatch!"
    msg_error "  expected: $expected"
    msg_error "  got:      $actual"
    return 1
}

function download_iso() {
    local url="$1"
    local filename="$2"

    select_iso_storage
    local iso_dir
    iso_dir=$(iso_storage_path "$ISO_STORAGE")
    local iso_path="${iso_dir}/${filename}"

    if [[ -f "$iso_path" ]]; then
        if [[ "$NON_INTERACTIVE" != "yes" ]] && \
           ! whiptail --backtitle "Proxmox VE PBS Install Script" \
             --title "ISO EXISTS" \
             --yesno "ISO '$filename' already exists.\n\nUse existing file?" 10 60; then
            msg_info "Removing existing ISO"
            rm -f "$iso_path"
            msg_ok "Removed"
        else
            # Verify existing file if checksum known
            if [[ -n "$ISO_EXPECTED_SHA" ]]; then
                if verify_iso_checksum "$iso_path" "$ISO_EXPECTED_SHA"; then
                    ISO_PATH="$iso_path"
                    msg_ok "Using existing verified ISO: $filename"
                    return 0
                else
                    msg_warn "Existing ISO failed checksum — re-downloading"
                    rm -f "$iso_path"
                fi
            else
                ISO_PATH="$iso_path"
                msg_ok "Using existing ISO (unverified): $filename"
                return 0
            fi
        fi
    fi

    msg_info "Downloading $filename"
    # shellcheck disable=SC2016
    if wget --tries=2 --timeout=60 --progress=bar:force:noscroll "$url" -O "$iso_path" 2>&1 | \
        stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
        whiptail --gauge "Downloading PBS ISO..." 8 60 0; then
        msg_ok "Downloaded $filename"
    else
        msg_error "Download failed"
        rm -f "$iso_path"
        exit 1
    fi

    verify_iso_checksum "$iso_path" "$ISO_EXPECTED_SHA" || {
        rm -f "$iso_path"
        exit 1
    }

    ISO_PATH="$iso_path"
}

function select_local_iso() {
    select_iso_storage
    local iso_dir
    iso_dir=$(iso_storage_path "$ISO_STORAGE")

    local iso_list=()
    while IFS= read -r iso_file; do
        local base size
        base=$(basename "$iso_file")
        size=$(du -h "$iso_file" 2>/dev/null | cut -f1)
        iso_list+=("$base" "Size: $size")
    done < <(find "$iso_dir" -maxdepth 1 -type f -name "*.iso" 2>/dev/null | sort)

    if ((${#iso_list[@]} == 0)); then
        msg_error "No ISO files found in $iso_dir"
        exit 1
    fi

    local chosen
    chosen=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "Local ISO Files" \
        --menu "Select a local ISO:" 20 80 10 \
        "${iso_list[@]}" 3>&1 1>&2 2>&3) || exit_script

    ISO_PATH="${iso_dir}/${chosen}"
    ISO_BASENAME="$chosen"
    msg_ok "Using local ISO: $chosen"
}

#################################################################################
# Disk Storage Selection                                                         #
#################################################################################

function select_disk_storage() {
    local menu_items=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag stype free
        tag=$(echo "$line" | awk '{print $1}')
        stype=$(echo "$line" | awk '{print $2}')
        free=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf "%9sB", $6}')
        [[ -z "$tag" ]] && continue
        menu_items+=("$tag" "Type: $stype, Free: $free")
    done < <(pvesm status -content images 2>/dev/null)

    if ((${#menu_items[@]} == 0)); then
        msg_error "No storage configured with 'images' content"
        exit 1
    fi

    if ((${#menu_items[@]} == 2)) || [[ "$NON_INTERACTIVE" == "yes" ]]; then
        STORAGE="${menu_items[0]}"
        msg_ok "Using disk storage: $STORAGE"
        return
    fi

    STORAGE=$(whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "DISK STORAGE" \
        --menu "Select storage for the PBS VM disks:" 18 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using disk storage: $STORAGE"
}

#################################################################################
# VM Creation                                                                    #
#################################################################################

function create_vm() {
    msg_info "Creating PBS VM (ID: $VMID)"

    local network_opts="virtio,bridge=${BRG},macaddr=${MAC}"
    [[ -n "$VLAN" ]] && network_opts+=",tag=${VLAN}"
    [[ -n "$MTU" && "$MTU" != "$DEFAULT_MTU" ]] && network_opts+=",mtu=${MTU}"

    local -a args=(
        --agent "$([[ "$QEMU_AGENT" == "yes" ]] && echo "enabled=1,fstrim_cloned_disks=1" || echo "enabled=0")"
        --tablet 0
        --localtime 1
        --bios ovmf
        --machine "$MACHINE"
        --cpu "$CPU_TYPE"
        --cores "$CORE_COUNT"
        --sockets 1
        --memory "$RAM_SIZE"
        --balloon "$([[ "$BALLOON" == "yes" ]] && echo "$RAM_SIZE" || echo 0)"
        --name "$HN"
        --tags "$VM_TAG"
        --net0 "$network_opts"
        --onboot 1
        --ostype l26
        --scsihw virtio-scsi-single
    )
    [[ "$PROTECTION" == "yes" ]] && args+=(--protection 1)
    [[ "$SERIAL_CONSOLE" == "yes" ]] && args+=(--serial0 socket --vga serial0)

    if ! qm create "$VMID" "${args[@]}" &>"/tmp/qm-create-${VMID}.log"; then
        msg_error "Failed to create VM shell — see /tmp/qm-create-${VMID}.log"
        cat "/tmp/qm-create-${VMID}.log" >&2
        exit 1
    fi
    msg_ok "VM shell created"
}

function attach_disks() {
    msg_info "Creating EFI disk (${EFI_DISK_SIZE})"
    qm set "$VMID" --efidisk0 "${STORAGE}:1,size=${EFI_DISK_SIZE},efitype=4m,pre-enrolled-keys=0" &>/dev/null
    msg_ok "EFI disk attached"

    msg_info "Allocating OS disk (${DISK_SIZE})"
    # Strip trailing G/M suffix for pvesm alloc which wants bytes or K
    local disk_size_arg="$DISK_SIZE"
    [[ ! "$disk_size_arg" =~ [GMKT]$ ]] && disk_size_arg="${disk_size_arg}G"

    local disk_opts="${STORAGE}:${DISK_SIZE%[GMKTgmkt]},format=raw"
    # Modern approach: let qm provision via volume shorthand
    local main_disk="${STORAGE}:${DISK_SIZE%[GMKTgmkt]}"
    [[ -n "$DISK_CACHE" ]] && main_disk+=",cache=${DISK_CACHE}"
    main_disk+=",iothread=1,ssd=1,discard=on"

    local retry=5
    for ((i=1; i<=retry; i++)); do
        if qm set "$VMID" --scsi0 "$main_disk" &>"/tmp/qm-disk-${VMID}.log"; then
            msg_ok "OS disk attached"
            break
        fi
        msg_warn "Disk attach attempt $i/$retry failed — retrying"
        sleep 3
        if ((i == retry)); then
            cat "/tmp/qm-disk-${VMID}.log" >&2
            msg_error "Could not attach OS disk"
            exit 1
        fi
    done

    msg_info "Attaching installation ISO"
    # Use the ISO storage pool:iso/filename reference
    local iso_ref
    if [[ "$ISO_STORAGE" != "local" && -n "$ISO_STORAGE" ]]; then
        iso_ref="${ISO_STORAGE}:iso/${ISO_BASENAME}"
    else
        iso_ref="local:iso/${ISO_BASENAME}"
    fi
    qm set "$VMID" --ide2 "${iso_ref},media=cdrom" &>/dev/null
    msg_ok "Installation ISO attached"

    msg_info "Setting boot order (CD-ROM first)"
    qm set "$VMID" --boot "order=ide2;scsi0" &>/dev/null
    msg_ok "Boot order set"
}

function set_vm_description() {
    local creation_date
    creation_date=$(date +"%Y-%m-%d %H:%M:%S %Z")
    local sha_line="unverified"
    [[ -n "$ISO_EXPECTED_SHA" ]] && sha_line="${ISO_EXPECTED_SHA:0:16}…"

    local description
    description=$(cat <<EOF
<div align='center'>
  <h2>Proxmox Backup Server VM</h2>
  <p><strong>Created:</strong> ${creation_date}</p>
  <p><strong>ISO:</strong> ${ISO_BASENAME}</p>
  <p><strong>SHA256:</strong> ${sha_line}</p>
  <hr>
  <table style='text-align:left'>
    <tr><td><strong>VM ID:</strong></td><td>${VMID}</td></tr>
    <tr><td><strong>Hostname:</strong></td><td>${HN}</td></tr>
    <tr><td><strong>CPU:</strong></td><td>${CORE_COUNT} × ${CPU_TYPE}</td></tr>
    <tr><td><strong>RAM:</strong></td><td>${RAM_SIZE} MiB</td></tr>
    <tr><td><strong>Disk:</strong></td><td>${DISK_SIZE} on ${STORAGE}</td></tr>
    <tr><td><strong>Network:</strong></td><td>${BRG}${VLAN:+ (VLAN ${VLAN})}</td></tr>
    <tr><td><strong>MAC:</strong></td><td>${MAC}</td></tr>
  </table>
  <hr>
  <p><a href='https://www.proxmox.com/en/proxmox-backup-server' target='_blank' rel='noopener'>
    Proxmox Backup Server home
  </a></p>
  <p>After installation, reach the web UI at <code>https://&lt;VM-IP&gt;:8007</code></p>
</div>
EOF
)
    qm set "$VMID" --description "$description" &>/dev/null
}

#################################################################################
# Post-install Helpers                                                           #
#################################################################################

function show_post_install_info() {
    [[ "$NON_INTERACTIVE" == "yes" ]] && return 0
    whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "POST-INSTALLATION STEPS" \
        --msgbox "PBS installation steps:

 1. Boot the VM from the attached ISO
 2. Select 'Install Proxmox Backup Server (Graphical)'
 3. Accept the EULA and choose target disk
 4. Set timezone and root password
 5. Configure network (IP, gateway, DNS, hostname)
 6. Finish install and reboot
 7. Log in to the web UI at https://<IP>:8007

After first login, add a datastore, a remote PVE host, and a backup schedule.

Press Enter to continue..." 20 74
}

function configure_post_install() {
    [[ "$NON_INTERACTIVE" == "yes" ]] && return 0
    if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "POST-INSTALLATION" \
        --yesno "Remove installer ISO and set boot from disk?" 10 60; then
        return 0
    fi

    msg_info "Stopping VM"
    qm stop "$VMID" &>/dev/null || true
    local timeout=30
    while [[ $timeout -gt 0 ]] && qm status "$VMID" 2>/dev/null | grep -q "running"; do
        sleep 1; ((timeout--))
    done
    msg_ok "VM stopped"

    msg_info "Removing installation ISO"
    qm set "$VMID" --delete ide2 &>/dev/null || true
    msg_ok "ISO detached"

    msg_info "Setting disk-only boot order"
    qm set "$VMID" --boot "order=scsi0" &>/dev/null
    msg_ok "Boot order set to disk"

    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "AUTO-START" \
        --yesno "Enable auto-start on host boot?" 8 60; then
        qm set "$VMID" --onboot 1 --startup "order=1,up=30" &>/dev/null
        msg_ok "Auto-start enabled"
    fi

    if whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "START VM" \
        --yesno "Start the PBS VM now?" 8 60; then
        msg_info "Starting VM"
        qm start "$VMID"
        msg_ok "PBS VM started"
    fi
}

#################################################################################
# Main                                                                           #
#################################################################################

parse_args "$@"

header_info
echo
if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    read -rsp "Press Enter to continue..." -n1 _ && echo
fi

msg_ok "Initialising Proxmox Backup Server VM creation"

check_root
check_dependencies
arch_check
pve_check
ssh_check

if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ! whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "Proxmox Backup Server VM" \
        --yesno "This script will create a new Proxmox Backup Server VM.

Requirements:
  - Proxmox VE 8.1+ or 9.x
  - 4+ GB RAM available on host
  - 32+ GB free on target storage
  - Working network bridge (default: ${DEFAULT_BRIDGE})
  - Internet access (for ISO download)

Proceed with VM creation?" 17 70; then
        exit_script
    fi
fi

# Configure
start_script

# Validate bridge
verify_bridge_exists "$BRG"

# Summary
if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    whiptail --backtitle "Proxmox VE PBS Install Script" \
        --title "CONFIGURATION SUMMARY" \
        --msgbox "VM Configuration

VMID:     $VMID
Hostname: $HN
Machine:  $MACHINE / OVMF
CPU:      $CORE_COUNT × $CPU_TYPE
RAM:      $RAM_SIZE MiB
Disk:     $DISK_SIZE
Bridge:   $BRG${VLAN:+ (VLAN $VLAN)}
MAC:      $MAC
Tags:     $VM_TAG

Press Enter to proceed..." 20 70
fi

# Temp workdir
TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# ISO discovery + download
select_iso

# Disk storage selection
select_disk_storage

# Build VM
create_vm
attach_disks
set_vm_description

msg_ok "PBS VM created successfully (ID: $VMID, Name: $HN)"

# Startup and post-install flow
if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starting PBS VM"
    qm start "$VMID"
    msg_ok "PBS VM started"
    show_post_install_info
    if [[ "$NON_INTERACTIVE" != "yes" ]]; then
        if whiptail --backtitle "Proxmox VE PBS Install Script" \
            --title "INSTALLATION" \
            --yesno "Once the PBS installer has finished and the VM has rebooted into the installed system, select Yes to detach the ISO and set disk-first boot order.

Is the PBS installation finished?" 12 70; then
            configure_post_install
        fi
    fi
else
    msg_info "VM created but not started"
    echo -e "${TAB}Start manually with: ${GN}qm start $VMID${CL}"
fi

popd >/dev/null

# Final summary
echo
msg_ok "Proxmox Backup Server VM setup complete!"
echo
echo -e "${INFO} ${HA}VM Information${CL}"
echo -e "${TAB}ID:       ${GN}$VMID${CL}"
echo -e "${TAB}Name:     ${GN}$HN${CL}"
echo -e "${TAB}Storage:  ${GN}$STORAGE${CL}"
echo -e "${TAB}ISO:      ${GN}$ISO_BASENAME${CL}"
echo -e "${TAB}MAC:      ${GN}$MAC${CL}"
echo
echo -e "${INFO} ${HA}Console Access${CL}"
if [[ "$SERIAL_CONSOLE" == "yes" ]]; then
    echo -e "${TAB}VGA:      ${GN}qm terminal $VMID${CL}"
    echo -e "${TAB}Serial:   ${GN}qm terminal $VMID -iface serial0${CL}"
else
    echo -e "${TAB}Console:  ${GN}qm terminal $VMID${CL}"
fi
echo
echo -e "${INFO} ${HA}After Installation${CL}"
echo -e "${TAB}Web UI:   ${GN}https://<PBS-IP>:8007${CL}"
echo -e "${TAB}Login:    ${GN}root@pam${CL} (password set during install)"
echo

exit 0
