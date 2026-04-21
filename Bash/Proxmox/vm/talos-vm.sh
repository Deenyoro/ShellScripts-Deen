#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# Purpose: Automate the creation of a Talos Linux VM in Proxmox VE
# Integrates with the Sidero Image Factory (factory.talos.dev) to build
# customised ISO / raw / qcow2 images with optional system extensions,
# SecureBoot variants, and TPM. Supports single- or multi-node creation.
#
# Usage:
#   talos-vm.sh                # interactive
#   talos-vm.sh --defaults     # non-interactive with defaults (vanilla schematic)
#   talos-vm.sh --count 3      # create 3 sibling VMs with sequential IDs/hostnames
#   talos-vm.sh --help         # show usage
#
# Dependencies: whiptail, wget, curl, jq, openssl, numfmt, awk, sed, zstd, xz,
#               Proxmox CLI tools (qm, pvesm, pvesh, pveversion)

set -Eeuo pipefail

#################################################################################
# Configuration Settings                                                         #
#################################################################################

# Image Factory endpoints
IMAGE_FACTORY_URL="https://factory.talos.dev"
TALOS_GITHUB_API="https://api.github.com/repos/siderolabs/talos/releases"

# Vanilla schematic (no customisations) — factory.talos.dev publishes this
# deterministically as the SHA256 of an empty `customization:` block.
DEFAULT_SCHEMATIC="376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba"

# Fallback stable version (current latest: v1.12.6 published 2026-03-19).
FALLBACK_TALOS_VERSION="v1.12.6"

# Defaults
STARTING_VM_ID=111
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MTU="1500"
DEFAULT_DISK_SIZE="80G"
DEFAULT_RAM_SIZE="4096"
DEFAULT_CPU_CORES="4"

# CLI flags
NON_INTERACTIVE="no"
VM_COUNT=1
SHOW_PRERELEASES="no"

#################################################################################
# Color and Message Formatting                                                   #
#################################################################################

CL="\033[m"
GN="\033[1;92m"
RD="\033[01;31m"
YL="\033[01;33m"
DGN="\033[32m"
BGN="\033[4;92m"
BL="\033[36m"
HA="\033[1;34m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
WARN="${YL}!${CL}"
BFR="\\r\\033[K"
HOLD="-"
INFO="${GN}◉${CL}"
TAB="  "

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

#################################################################################
# Global State                                                                   #
#################################################################################

TEMP_DIR=""
VMID=""
MACHINE=""
CPU_TYPE=""
BRG=""
HN=""
IMAGE_FILE=""
IMAGE_PATH=""
ISO_STORAGE=""
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
SCHEMATIC_ID=""
TALOS_VERSION=""
SELECTED_EXTENSIONS=()
IMAGE_FORMAT="iso"
SERIAL_CONSOLE=""
QEMU_AGENT=""
BALLOON=""
MAC=""
INSTALLER_IMAGE=""
ARCH="amd64"
SECUREBOOT="no"
ENABLE_TPM="no"
VM_ROLE="controlplane"
HOST_ARCH=""

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

Create Talos Linux VMs in Proxmox VE using the Sidero Image Factory.

Options:
  --defaults        Skip interactive prompts; vanilla schematic, stable image
  --count N         Create N sibling VMs (sequential VMIDs, HN suffix -1..-N)
  --prereleases     Include alpha/beta/rc Talos versions in the picker
  -h, --help        Show this help

Examples:
  $0                          Launch interactive wizard (single VM)
  $0 --defaults               Create one vanilla Talos VM
  $0 --defaults --count 3     Create a 3-node control-plane
EOF
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --defaults)      NON_INTERACTIVE="yes"; shift ;;
            --count)         VM_COUNT="${2:-1}"; shift 2 ;;
            --prereleases)   SHOW_PRERELEASES="yes"; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               msg_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
    [[ "$VM_COUNT" =~ ^[0-9]+$ && "$VM_COUNT" -ge 1 ]] || {
        msg_error "--count must be a positive integer"; exit 2
    }
}

#################################################################################
# Dependencies                                                                   #
#################################################################################

function check_dependencies() {
    local deps=(whiptail pvesh pvesm qm wget curl openssl jq numfmt awk sed)
    local optional_deps=(zstd xz)
    declare -A cmd_pkg_map=(
        [whiptail]=whiptail
        [pvesh]=pve-manager
        [pvesm]=pve-manager
        [qm]=pve-manager
        [wget]=wget
        [curl]=curl
        [openssl]=openssl
        [jq]=jq
        [numfmt]=coreutils
        [awk]=mawk
        [sed]=sed
        [zstd]=zstd
        [xz]=xz-utils
    )

    # Optional deps: warn only
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_warn "$cmd not installed — needed for compressed raw/qcow2 downloads"
        fi
    done

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
        *) msg_error "Required dependencies missing. Exiting."; exit 1 ;;
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
    HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$HOST_ARCH" in
        amd64|x86_64) ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            msg_error "Unsupported host architecture: $HOST_ARCH"
            exit 1
            ;;
    esac
    msg_ok "Host architecture: ${HOST_ARCH} → Talos image arch: ${ARCH}"
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
        if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's recommended to use the Proxmox shell instead of SSH.\nSSH can cause issues with interactive elements.\n\nContinue anyway?" 12 62; then
            exit_script
        fi
    fi
}

#################################################################################
# VM ID / Utilities                                                              #
#################################################################################

function get_valid_nextid() {
    local try_id
    try_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "$STARTING_VM_ID")
    [[ "$try_id" -lt "$STARTING_VM_ID" ]] && try_id=$STARTING_VM_ID
    while true; do
        if [[ -f "/etc/pve/qemu-server/${try_id}.conf" ]]; then ((try_id++)); continue; fi
        if [[ -f "/etc/pve/lxc/${try_id}.conf" ]]; then ((try_id++)); continue; fi
        if command -v lvs &>/dev/null && \
           lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try_id}($|[-_])"; then
            ((try_id++)); continue
        fi
        break
    done
    echo "$try_id"
}

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
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
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
# Image Factory API                                                              #
#################################################################################

function get_talos_versions() {
    local out
    if out=$(curl -fsSL --connect-timeout 10 "${IMAGE_FACTORY_URL}/versions" 2>/dev/null); then
        echo "$out"
        return 0
    fi
    # Fallback to GitHub latest
    if out=$(curl -fsSL --connect-timeout 10 "${TALOS_GITHUB_API}/latest" 2>/dev/null); then
        local tag
        tag=$(echo "$out" | jq -r '.tag_name')
        if [[ -n "$tag" && "$tag" != "null" ]]; then
            echo "[\"$tag\"]"
            return 0
        fi
    fi
    # Ultimate fallback
    echo "[\"${FALLBACK_TALOS_VERSION}\"]"
}

function get_system_extensions() {
    local version="$1"
    curl -fsSL --connect-timeout 10 \
        "${IMAGE_FACTORY_URL}/version/${version}/extensions/official" 2>/dev/null || echo "[]"
}

function create_schematic() {
    local -a extensions=("$@")

    if [ ${#extensions[@]} -eq 0 ]; then
        SCHEMATIC_ID="$DEFAULT_SCHEMATIC"
        msg_ok "Using default schematic (vanilla, no extensions)"
        return 0
    fi

    msg_info "Creating custom schematic with ${#extensions[@]} extension(s)"

    # Build YAML
    local body="customization:
  systemExtensions:
    officialExtensions:"
    for ext in "${extensions[@]}"; do
        body+=$'\n      - '"$ext"
    done

    local response
    if ! response=$(curl -fsSL -X POST \
        --connect-timeout 10 \
        -H "Content-Type: application/yaml" \
        --data-binary "$body" \
        "${IMAGE_FACTORY_URL}/schematics" 2>/dev/null); then
        msg_error "Failed to POST schematic to Image Factory"
        return 1
    fi

    SCHEMATIC_ID=$(echo "$response" | jq -r '.id' 2>/dev/null || true)
    if [[ -z "$SCHEMATIC_ID" || "$SCHEMATIC_ID" == "null" ]]; then
        msg_error "Image Factory did not return a valid schematic id"
        msg_error "Response: $response"
        return 1
    fi
    msg_ok "Schematic registered: ${SCHEMATIC_ID:0:16}…"
}

#################################################################################
# VM Configuration                                                               #
#################################################################################

function default_settings() {
    VMID="${VMID:-$(get_valid_nextid)}"
    MACHINE="q35"
    DISK_CACHE=""
    HN="talos${VMID}"
    CPU_TYPE="host"
    CORE_COUNT="$DEFAULT_CPU_CORES"
    RAM_SIZE="$DEFAULT_RAM_SIZE"
    DISK_SIZE="$DEFAULT_DISK_SIZE"
    BRG="${BRG:-$DEFAULT_BRIDGE}"
    MAC=$(generate_mac)
    VLAN=""
    MTU="$DEFAULT_MTU"
    START_VM="yes"
    VM_TAG="kubernetes;talos;${VM_ROLE}"
    EFI_DISK_SIZE="4M"
    SERIAL_CONSOLE="yes"
    QEMU_AGENT="yes"
    BALLOON="no"              # Talos prefers fixed memory
    IMAGE_FORMAT="iso"
    SECUREBOOT="no"
    ENABLE_TPM="no"
    TALOS_VERSION="${TALOS_VERSION:-$FALLBACK_TALOS_VERSION}"
    msg_ok "Default settings applied"
}

function advanced_settings() {
    local bt="Proxmox VE Talos Linux Install Script"
    VMID=$(whiptail --backtitle "$bt" \
        --inputbox "Virtual Machine ID (Default: $(get_valid_nextid))" 8 60 "$(get_valid_nextid)" \
        --title "VM ID" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$VMID" =~ ^[0-9]+$ ]] || { msg_error "VM ID must be numeric"; exit 1; }

    VM_ROLE=$(whiptail --backtitle "$bt" \
        --title "NODE ROLE" --radiolist "Select Talos node role:" 11 60 3 \
        "controlplane" "Kubernetes control plane" ON \
        "worker"       "Kubernetes worker" OFF \
        "standalone"   "Single-node / non-cluster" OFF \
        3>&1 1>&2 2>&3) || exit_script

    HN=$(whiptail --backtitle "$bt" \
        --inputbox "Hostname" 8 60 "talos${VMID}" \
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
        "host"          "Host (best performance)" ON \
        "x86-64-v2-AES" "Modern baseline" OFF \
        "kvm64"         "KVM64 (compatibility)" OFF \
        "max"           "Maximum features" OFF \
        3>&1 1>&2 2>&3) || exit_script

    CORE_COUNT=$(whiptail --backtitle "$bt" \
        --inputbox "CPU cores" 8 60 "$DEFAULT_CPU_CORES" \
        --title "CPU CORES" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$CORE_COUNT" =~ ^[0-9]+$ ]] || { msg_error "Cores must be numeric"; exit 1; }

    RAM_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "RAM size in MiB" 8 60 "$DEFAULT_RAM_SIZE" \
        --title "RAM" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    [[ "$RAM_SIZE" =~ ^[0-9]+$ ]] || { msg_error "RAM must be numeric"; exit 1; }

    DISK_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "OS disk size (e.g. 80G)" 8 60 "$DEFAULT_DISK_SIZE" \
        --title "DISK SIZE" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    local bridges
    mapfile -t bridges < <(get_available_bridges)
    if ((${#bridges[@]} > 0)); then
        local br_items=()
        for b in "${bridges[@]}"; do br_items+=("$b" "existing bridge"); done
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
        --inputbox "VM tags (semicolon-separated)" 8 60 "kubernetes;talos;${VM_ROLE}" \
        --title "TAGS" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script
    EFI_DISK_SIZE=$(whiptail --backtitle "$bt" \
        --inputbox "EFI disk size" 8 60 "4M" \
        --title "EFI DISK" --cancel-button "Exit" 3>&1 1>&2 2>&3) || exit_script

    whiptail --backtitle "$bt" --title "SERIAL CONSOLE" \
        --yesno "Enable serial console?" 8 60 && SERIAL_CONSOLE="yes" || SERIAL_CONSOLE="no"
    whiptail --backtitle "$bt" --title "QEMU AGENT" \
        --yesno "Enable QEMU Guest Agent?\n(auto-adds siderolabs/qemu-guest-agent extension)" 10 60 \
        && QEMU_AGENT="yes" || QEMU_AGENT="no"
    whiptail --backtitle "$bt" --title "BALLOONING" \
        --defaultno --yesno "Enable memory ballooning?\n(Talos generally prefers fixed memory)" 10 60 \
        && BALLOON="yes" || BALLOON="no"
    whiptail --backtitle "$bt" --title "SECUREBOOT" \
        --defaultno --yesno "Use SecureBoot-enabled Talos image?\n(adds -secureboot suffix to Image Factory asset)" 10 60 \
        && SECUREBOOT="yes" || SECUREBOOT="no"
    if [[ "$SECUREBOOT" == "yes" ]]; then
        whiptail --backtitle "$bt" --title "TPM" \
            --yesno "Attach a virtual TPM 2.0 device? (recommended with SecureBoot)" 9 60 \
            && ENABLE_TPM="yes" || ENABLE_TPM="no"
    fi

    IMAGE_FORMAT=$(whiptail --backtitle "$bt" \
        --title "IMAGE FORMAT" --radiolist "Select image format:" 12 60 3 \
        "iso"   "ISO (traditional install)" ON \
        "raw"   "Raw disk image (metal-${ARCH}.raw.zst)" OFF \
        "qcow2" "QCOW2 disk image" OFF \
        3>&1 1>&2 2>&3) || exit_script

    whiptail --backtitle "$bt" --title "START VM" \
        --yesno "Start VM(s) when creation completes?" 8 60 \
        && START_VM="yes" || START_VM="no"

    msg_ok "Advanced settings configured"
}

function start_script() {
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        default_settings
        return
    fi
    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "SETTINGS" \
        --yesno "Use default settings?\n\n(Select No to configure advanced options)" \
        --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

#################################################################################
# Talos Version + Extension Selection                                            #
#################################################################################

function select_talos_version() {
    msg_info "Fetching Talos versions"
    local versions_json
    versions_json=$(get_talos_versions)
    msg_ok "Fetched version list"

    # Convert JSON array to newline-delimited list
    local all_versions
    mapfile -t all_versions < <(echo "$versions_json" | jq -r '.[]' 2>/dev/null | tr -d ' "')
    if [[ ${#all_versions[@]} -eq 0 ]]; then
        msg_warn "No versions returned — falling back to ${FALLBACK_TALOS_VERSION}"
        TALOS_VERSION="$FALLBACK_TALOS_VERSION"
        return
    fi

    # Filter stable unless --prereleases
    local stable=()
    local pre=()
    for v in "${all_versions[@]}"; do
        if [[ "$v" =~ (alpha|beta|rc) ]]; then
            pre+=("$v")
        else
            stable+=("$v")
        fi
    done

    local candidates=()
    if [[ "$SHOW_PRERELEASES" == "yes" ]]; then
        candidates=("${all_versions[@]}")
    else
        candidates=("${stable[@]}")
    fi

    # Sort descending (newest first) via sort -V
    mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -rV)

    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        TALOS_VERSION="${candidates[0]:-$FALLBACK_TALOS_VERSION}"
        msg_ok "Talos version: $TALOS_VERSION (auto-selected newest stable)"
        return
    fi

    local menu_items=()
    # Show the 15 most recent versions
    local limit=15
    for v in "${candidates[@]}"; do
        local tag=""
        [[ "$v" =~ (alpha|beta|rc) ]] && tag=" [pre-release]"
        menu_items+=("$v" "Talos Linux $v${tag}")
        ((--limit == 0)) && break
    done

    TALOS_VERSION=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "TALOS VERSION" \
        --menu "Select Talos version (newest first):" 22 70 14 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Talos version selected: $TALOS_VERSION"
}

function select_system_extensions() {
    SELECTED_EXTENSIONS=()
    if [[ "$QEMU_AGENT" == "yes" ]]; then
        SELECTED_EXTENSIONS+=("siderolabs/qemu-guest-agent")
        msg_ok "Auto-selected siderolabs/qemu-guest-agent"
    fi

    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        return
    fi

    msg_info "Fetching available system extensions"
    local extensions_json
    extensions_json=$(get_system_extensions "$TALOS_VERSION")
    msg_ok "Extensions fetched"

    # Build the checklist
    local checklist=()
    while IFS= read -r entry; do
        local name ref desc
        name=$(echo "$entry" | jq -r '.name // empty' 2>/dev/null)
        ref=$(echo "$entry"  | jq -r '.ref  // empty' 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && continue

        case "$name" in
            *qemu-guest-agent*)  desc="QEMU Guest Agent" ;;
            *i915-ucode*)        desc="Intel i915 firmware" ;;
            *i915*)              desc="Intel iGPU driver" ;;
            *amd-ucode*)         desc="AMD CPU microcode" ;;
            *intel-ucode*)       desc="Intel CPU microcode" ;;
            *nvidia-container-toolkit*) desc="NVIDIA container runtime" ;;
            *nvidia-fabricmanager*)     desc="NVIDIA fabric manager" ;;
            *nonfree-kmod-nvidia*)      desc="NVIDIA proprietary driver" ;;
            *gvisor*)            desc="gVisor sandbox runtime" ;;
            *gasket-driver*)     desc="Google Coral (Gasket) driver" ;;
            *iscsi-tools*)       desc="iSCSI initiator tools" ;;
            *drbd*)              desc="DRBD replication kmod" ;;
            *zfs*)               desc="ZFS filesystem kmod" ;;
            *tailscale*)         desc="Tailscale extension" ;;
            *) desc="${ref##*/}" ;;
        esac

        local state="OFF"
        for ext in "${SELECTED_EXTENSIONS[@]}"; do
            [[ "$ext" == "$name" ]] && { state="ON"; break; }
        done
        checklist+=("$name" "$desc" "$state")
    done < <(echo "$extensions_json" | jq -c '.[]' 2>/dev/null)

    if [[ ${#checklist[@]} -eq 0 ]]; then
        msg_warn "No extensions returned for $TALOS_VERSION"
        return
    fi

    local selected
    if ! selected=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "SYSTEM EXTENSIONS" \
        --checklist "Select official extensions to bake into the image\n(Space to toggle, Enter to confirm, Cancel to skip)" \
        22 80 12 \
        "${checklist[@]}" 3>&1 1>&2 2>&3); then
        msg_warn "Extension selection cancelled — keeping current set"
        return
    fi

    SELECTED_EXTENSIONS=()
    # whiptail returns: "ext1" "ext2" "ext3" with quotes
    local ext
    for ext in $selected; do
        ext="${ext%\"}"; ext="${ext#\"}"
        [[ -n "$ext" ]] && SELECTED_EXTENSIONS+=("$ext")
    done

    msg_ok "Selected ${#SELECTED_EXTENSIONS[@]} extension(s)"
}

#################################################################################
# Image Handling                                                                  #
#################################################################################

function asset_basename() {
    # Returns the asset filename the Image Factory serves for our format
    local sb_suffix=""
    [[ "$SECUREBOOT" == "yes" ]] && sb_suffix="-secureboot"

    case "$IMAGE_FORMAT" in
        iso)   echo "metal-${ARCH}${sb_suffix}.iso" ;;
        raw)   echo "metal-${ARCH}${sb_suffix}.raw.zst" ;;
        qcow2) echo "metal-${ARCH}${sb_suffix}.qcow2" ;;
        *)     echo "metal-${ARCH}${sb_suffix}.iso" ;;
    esac
}

function local_filename() {
    local asset="$1"
    echo "talos-${TALOS_VERSION}-${SCHEMATIC_ID:0:16}-${asset}"
}

function iso_storage_path() {
    local stg="$1"
    local path
    path=$(pvesm path "${stg}:iso/_" 2>/dev/null | sed 's|/_$||' || true)
    [[ -z "$path" ]] && path="/var/lib/vz/template/iso"
    mkdir -p "$path"
    echo "$path"
}

function select_iso_storage() {
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
        msg_warn "No 'iso' content storage — falling back to local"
        ISO_STORAGE="local"
        return
    fi
    if ((${#menu_items[@]} == 2)) || [[ "$NON_INTERACTIVE" == "yes" ]]; then
        ISO_STORAGE="${menu_items[0]}"
        msg_ok "Using ISO storage: $ISO_STORAGE"
        return
    fi
    ISO_STORAGE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "ISO STORAGE" \
        --menu "Select storage for Talos ISO:" 18 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using ISO storage: $ISO_STORAGE"
}

function download_talos_image() {
    local asset filename url target
    asset=$(asset_basename)
    filename=$(local_filename "$asset")
    url="${IMAGE_FACTORY_URL}/image/${SCHEMATIC_ID}/${TALOS_VERSION}/${asset}"

    if [[ "$IMAGE_FORMAT" == "iso" ]]; then
        select_iso_storage
        local iso_dir
        iso_dir=$(iso_storage_path "$ISO_STORAGE")
        target="${iso_dir}/${filename}"
    else
        target="${TEMP_DIR}/${filename}"
    fi

    IMAGE_FILE="$filename"
    IMAGE_PATH="$target"

    if [[ -f "$target" && "$IMAGE_FORMAT" == "iso" ]]; then
        if [[ "$NON_INTERACTIVE" == "yes" ]] || whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "IMAGE EXISTS" \
            --yesno "Image '$filename' already exists.\n\nUse existing file?" 10 60; then
            msg_ok "Using existing image: $filename"
            return 0
        fi
        rm -f "$target"
    fi

    msg_info "Downloading $filename"
    # shellcheck disable=SC2016
    if wget --tries=2 --timeout=120 --progress=bar:force:noscroll "$url" -O "$target" 2>&1 | \
        stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
        whiptail --gauge "Downloading Talos $IMAGE_FORMAT..." 8 60 0; then
        msg_ok "Downloaded $filename"
    else
        msg_error "Download failed: $url"
        rm -f "$target"
        exit 1
    fi

    # Decompress raw.zst if needed
    if [[ "$filename" == *.zst ]]; then
        if ! command -v zstd &>/dev/null; then
            msg_error "zstd not installed — cannot decompress $filename"
            exit 1
        fi
        msg_info "Decompressing raw image"
        zstd -qd --rm "$target" -o "${target%.zst}"
        IMAGE_FILE="${filename%.zst}"
        IMAGE_PATH="${target%.zst}"
        msg_ok "Decompressed to $IMAGE_FILE"
    fi
}

function select_local_image() {
    select_iso_storage
    local iso_dir
    iso_dir=$(iso_storage_path "$ISO_STORAGE")

    local list=()
    while IFS= read -r f; do
        local base size
        base=$(basename "$f")
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        list+=("$base" "Size: $size")
    done < <(find "$iso_dir" -maxdepth 1 -type f \( -name "*.iso" -o -name "*talos*.img" \) 2>/dev/null | sort)

    if ((${#list[@]} == 0)); then
        msg_error "No ISO files found in $iso_dir"
        return 1
    fi

    local chosen
    chosen=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "Local Images" \
        --menu "Select a local image:" 20 80 10 \
        "${list[@]}" 3>&1 1>&2 2>&3) || return 1

    IMAGE_PATH="${iso_dir}/${chosen}"
    IMAGE_FILE="$chosen"
    IMAGE_FORMAT="iso"
    msg_ok "Using local image: $chosen"
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
    STORAGE=$(whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "DISK STORAGE" \
        --menu "Select storage for Talos VM disks:" 18 70 8 \
        "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using disk storage: $STORAGE"
}

#################################################################################
# VM Creation                                                                    #
#################################################################################

function qm_import_disk() {
    # Prefer modern `qm disk import`; fall back to deprecated `qm importdisk`.
    local vmid="$1" image="$2" storage="$3" fmt="${4:-}"
    if qm help disk 2>/dev/null | grep -q '^\s*import\b'; then
        if [[ -n "$fmt" ]]; then
            qm disk import "$vmid" "$image" "$storage" --format "$fmt"
        else
            qm disk import "$vmid" "$image" "$storage"
        fi
    else
        if [[ -n "$fmt" ]]; then
            qm importdisk "$vmid" "$image" "$storage" --format "$fmt"
        else
            qm importdisk "$vmid" "$image" "$storage"
        fi
    fi
}

function create_vm() {
    msg_info "Creating Talos VM (ID: $VMID, role: $VM_ROLE)"
    local network_opts="virtio,bridge=${BRG},macaddr=${MAC}"
    [[ -n "$VLAN" ]] && network_opts+=",tag=${VLAN}"
    [[ -n "$MTU" && "$MTU" != "$DEFAULT_MTU" ]] && network_opts+=",mtu=${MTU}"

    local -a args=(
        --agent "$([[ "$QEMU_AGENT" == "yes" ]] && echo "enabled=1,fstrim_cloned_disks=1" || echo "enabled=0")"
        --tablet 0
        --localtime 0          # Talos expects UTC
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
    [[ "$SERIAL_CONSOLE" == "yes" ]] && args+=(--serial0 socket --vga serial0)

    if ! qm create "$VMID" "${args[@]}" &>"/tmp/qm-create-${VMID}.log"; then
        msg_error "Failed to create VM shell — see /tmp/qm-create-${VMID}.log"
        cat "/tmp/qm-create-${VMID}.log" >&2
        exit 1
    fi
    msg_ok "VM shell created"
}

function attach_efi() {
    msg_info "Creating EFI disk"
    local efi_opts="${STORAGE}:1,efitype=4m"
    # SecureBoot: enroll keys; without SecureBoot: no enrollment
    if [[ "$SECUREBOOT" == "yes" ]]; then
        efi_opts+=",pre-enrolled-keys=1"
    else
        efi_opts+=",pre-enrolled-keys=0"
    fi
    qm set "$VMID" --efidisk0 "$efi_opts" &>/dev/null
    msg_ok "EFI disk attached"

    if [[ "$ENABLE_TPM" == "yes" ]]; then
        msg_info "Attaching TPM 2.0 state"
        qm set "$VMID" --tpmstate0 "${STORAGE}:1,version=v2.0" &>/dev/null
        msg_ok "TPM attached"
    fi
}

function attach_disks() {
    attach_efi

    case "$IMAGE_FORMAT" in
        iso)
            msg_info "Allocating OS disk (${DISK_SIZE})"
            local disk_opts="${STORAGE}:${DISK_SIZE%[GMKTgmkt]},iothread=1,ssd=1,discard=on"
            [[ -n "$DISK_CACHE" ]] && disk_opts+=",cache=${DISK_CACHE}"

            local retry=5
            for ((i=1; i<=retry; i++)); do
                if qm set "$VMID" --scsi0 "$disk_opts" &>"/tmp/qm-disk-${VMID}.log"; then
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
            local iso_ref
            if [[ -n "$ISO_STORAGE" && "$ISO_STORAGE" != "local" ]]; then
                iso_ref="${ISO_STORAGE}:iso/${IMAGE_FILE}"
            else
                iso_ref="local:iso/${IMAGE_FILE}"
            fi
            qm set "$VMID" --ide2 "${iso_ref},media=cdrom" &>/dev/null
            msg_ok "Installation ISO attached"

            qm set "$VMID" --boot "order=ide2;scsi0" &>/dev/null
            msg_ok "Boot order set (CD-ROM first)"
            ;;

        raw|qcow2)
            msg_info "Importing ${IMAGE_FORMAT} disk image"
            local fmt=""
            [[ "$IMAGE_FORMAT" == "qcow2" ]] && fmt="qcow2"

            if ! qm_import_disk "$VMID" "$IMAGE_PATH" "$STORAGE" "$fmt" &>"/tmp/qm-import-${VMID}.log"; then
                cat "/tmp/qm-import-${VMID}.log" >&2
                msg_error "Disk import failed"
                exit 1
            fi
            msg_ok "Disk imported"

            # Find the newly-added unused slot by parsing config JSON
            msg_info "Locating imported disk slot"
            local unused_slot unused_ref
            unused_slot=$(qm config "$VMID" | awk -F: '/^unused[0-9]+:/ {print $1; exit}')
            if [[ -z "$unused_slot" ]]; then
                msg_error "No unused disk slot appeared after import"
                exit 1
            fi
            unused_ref=$(qm config "$VMID" | awk -v k="$unused_slot" -F': ' '$1==k {print $2; exit}')
            msg_ok "Found imported disk at $unused_slot"

            msg_info "Attaching imported disk as scsi0"
            local attach_opts="${unused_ref},iothread=1,ssd=1,discard=on"
            [[ -n "$DISK_CACHE" ]] && attach_opts+=",cache=${DISK_CACHE}"
            qm set "$VMID" --scsi0 "$attach_opts" &>/dev/null
            # Clean up the unused slot reference
            qm set "$VMID" --delete "$unused_slot" &>/dev/null || true
            msg_ok "Disk attached as scsi0"

            # Resize to the configured disk size (grow only)
            if [[ -n "${DISK_SIZE:-}" ]]; then
                msg_info "Growing disk to ${DISK_SIZE}"
                qm resize "$VMID" scsi0 "$DISK_SIZE" &>/dev/null || \
                    msg_warn "Disk resize to ${DISK_SIZE} failed (already larger?)"
                msg_ok "Disk sized"
            fi

            qm set "$VMID" --boot "order=scsi0" &>/dev/null
            msg_ok "Boot order set (disk only)"
            ;;
    esac
}

function set_vm_description() {
    local creation_date
    creation_date=$(date +"%Y-%m-%d %H:%M:%S %Z")

    local ext_html=""
    if ((${#SELECTED_EXTENSIONS[@]} > 0)); then
        ext_html="<h4>System Extensions</h4><ul>"
        for ext in "${SELECTED_EXTENSIONS[@]}"; do
            ext_html+="<li><code>${ext}</code></li>"
        done
        ext_html+="</ul>"
    fi

    INSTALLER_IMAGE="factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TALOS_VERSION}"
    [[ "$SECUREBOOT" == "yes" ]] && \
        INSTALLER_IMAGE="factory.talos.dev/metal-installer-secureboot/${SCHEMATIC_ID}:${TALOS_VERSION}"

    local description
    description=$(cat <<EOF
<div align='center'>
  <h2>Talos Linux VM</h2>
  <p><strong>Created:</strong> ${creation_date}</p>
  <p><strong>Version:</strong> ${TALOS_VERSION} (${ARCH}${SECUREBOOT:+, SecureBoot})</p>
  <p><strong>Role:</strong> ${VM_ROLE}</p>
  <p><strong>Schematic:</strong> <code>${SCHEMATIC_ID:0:16}…</code></p>
  <p><strong>Image format:</strong> ${IMAGE_FORMAT}</p>
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
  ${ext_html}
  <hr>
  <p><strong>Installer image for upgrades:</strong></p>
  <pre><code>${INSTALLER_IMAGE}</code></pre>
  <hr>
  <p><a href='https://www.talos.dev/'>Talos documentation</a></p>
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
    whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "NEXT STEPS" \
        --msgbox "Talos VM ready.

  1. Boot the VM — it will come up in maintenance mode
  2. Get the node IP from the console
  3. Generate machine configs:
     talosctl gen config <cluster> https://<ip>:6443
  4. Apply:
     talosctl apply-config --insecure -n <ip> -f controlplane.yaml
  5. Bootstrap (first control-plane only):
     talosctl bootstrap -n <ip> --endpoints <ip> --talosconfig=./talosconfig

Installer image for upgrades:
  ${INSTALLER_IMAGE}

Press Enter to continue..." 22 78
}

function configure_post_install() {
    [[ "$IMAGE_FORMAT" != "iso" ]] && return 0
    [[ "$NON_INTERACTIVE" == "yes" ]] && return 0

    if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "POST-INSTALLATION" \
        --yesno "Remove installer ISO and boot from disk now?" 10 60; then
        return 0
    fi

    msg_info "Stopping VM"
    qm stop "$VMID" &>/dev/null || true
    local timeout=30
    while [[ $timeout -gt 0 ]] && qm status "$VMID" 2>/dev/null | grep -q "running"; do
        sleep 1; ((timeout--))
    done
    msg_ok "VM stopped"

    msg_info "Detaching installer ISO"
    qm set "$VMID" --delete ide2 &>/dev/null || true
    msg_ok "ISO detached"

    msg_info "Setting disk-only boot order"
    qm set "$VMID" --boot "order=scsi0" &>/dev/null
    msg_ok "Boot order set"

    if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "START VM" \
        --yesno "Start the VM now?" 8 60; then
        msg_info "Starting VM"
        qm start "$VMID"
        msg_ok "Talos VM started"
    fi
}

#################################################################################
# Per-VM build routine (loop-able for --count)                                   #
#################################################################################

function build_one_vm() {
    local seq="$1"
    local total="$2"
    local base_hn="$3"
    local base_vmid="$4"

    if ((total > 1)); then
        VMID=$((base_vmid + seq - 1))
        HN="${base_hn}-${seq}"
        MAC=$(generate_mac)
        # Confirm VMID is free — if not, bump to next available
        while [[ -f "/etc/pve/qemu-server/${VMID}.conf" ]] || [[ -f "/etc/pve/lxc/${VMID}.conf" ]]; do
            ((VMID++))
        done
    fi

    echo
    msg_ok "Building VM ${seq}/${total}: VMID=${VMID} HN=${HN}"

    verify_bridge_exists "$BRG"

    create_vm
    attach_disks
    set_vm_description
    msg_ok "VM ${VMID} (${HN}) created"

    if [[ "$START_VM" == "yes" ]]; then
        msg_info "Starting VM $VMID"
        qm start "$VMID"
        msg_ok "VM $VMID started"
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

msg_ok "Initialising Talos Linux VM creation (target count: ${VM_COUNT})"

check_root
check_dependencies
arch_check
pve_check
ssh_check

if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "Talos Linux VM" \
        --yesno "This script will create Talos Linux VM(s) via the Sidero Image Factory.

Features:
  - Version picker (stable only, or --prereleases to see rc/beta)
  - Optional system extensions baked into custom schematic
  - ISO / raw / qcow2 image formats
  - Optional SecureBoot + TPM 2.0
  - Multi-node creation with --count

Requirements:
  - Proxmox VE 8.1+ or 9.x
  - Internet access to ${IMAGE_FACTORY_URL}
  - Working network bridge (default: ${DEFAULT_BRIDGE})

Proceed?" 22 72; then
        exit_script
    fi
fi

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

# Collect settings
start_script
select_talos_version
select_system_extensions

# Build schematic (with extensions) — if none, falls back to vanilla
create_schematic "${SELECTED_EXTENSIONS[@]}"

# Image acquisition
download_or_local="download"
if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ! whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "IMAGE SOURCE" \
        --yesno "Download Talos image from Image Factory?\n\nChoose 'No' to pick an existing local image." 10 62; then
        download_or_local="local"
    fi
fi

if [[ "$download_or_local" == "download" ]]; then
    if ! download_talos_image; then
        msg_error "Image download failed"
        exit 1
    fi
else
    select_local_image || exit 1
fi

# Disk storage
select_disk_storage

# Summary
if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
        --title "CONFIGURATION SUMMARY" \
        --msgbox "VM Configuration (× ${VM_COUNT})

Base VMID:  $VMID
Base HN:    $HN
Version:    $TALOS_VERSION (${ARCH}${SECUREBOOT:+ +SecureBoot}${ENABLE_TPM:+ +TPM})
Schematic:  ${SCHEMATIC_ID:0:16}…
Role:       $VM_ROLE
Format:     $IMAGE_FORMAT
CPU:        $CORE_COUNT × $CPU_TYPE
RAM:        $RAM_SIZE MiB
Disk:       $DISK_SIZE on $STORAGE
Bridge:     $BRG${VLAN:+ (VLAN $VLAN)}
Extensions: ${#SELECTED_EXTENSIONS[@]}

Press Enter to create VM(s)..." 22 70
fi

# Build one or many
BASE_HN="$HN"
BASE_VMID="$VMID"
for ((seq=1; seq<=VM_COUNT; seq++)); do
    build_one_vm "$seq" "$VM_COUNT" "$BASE_HN" "$BASE_VMID"
done

# For a single-VM ISO install, offer the guided post-install cleanup
if [[ "$VM_COUNT" -eq 1 && "$IMAGE_FORMAT" == "iso" && "$START_VM" == "yes" ]]; then
    show_post_install_info
    if [[ "$NON_INTERACTIVE" != "yes" ]]; then
        if whiptail --backtitle "Proxmox VE Talos Linux Install Script" \
            --title "INSTALLATION" \
            --yesno "After Talos finishes installing to disk, select Yes to detach the ISO and set the boot order.\n\nIs installation complete?" 12 70; then
            configure_post_install
        fi
    fi
fi

popd >/dev/null

# Final summary
echo
msg_ok "Talos Linux VM setup complete!"
echo
echo -e "${INFO} ${HA}Summary${CL}"
echo -e "${TAB}Version:    ${GN}$TALOS_VERSION${CL}  ${DGN}(${ARCH}${SECUREBOOT:+, SecureBoot})${CL}"
echo -e "${TAB}Schematic:  ${GN}${SCHEMATIC_ID:0:16}…${CL}"
echo -e "${TAB}Format:     ${GN}$IMAGE_FORMAT${CL}"
echo -e "${TAB}Storage:    ${GN}$STORAGE${CL}"
echo -e "${TAB}VM count:   ${GN}$VM_COUNT${CL}"
echo

if ((${#SELECTED_EXTENSIONS[@]} > 0)); then
    echo -e "${INFO} ${HA}System Extensions${CL}"
    for ext in "${SELECTED_EXTENSIONS[@]}"; do
        echo -e "${TAB}• ${GN}$ext${CL}"
    done
    echo
fi

echo -e "${INFO} ${HA}Next Steps${CL}"
echo -e "${TAB}1. Boot VM(s) and note the reported IP"
echo -e "${TAB}2. Generate configs:  ${BL}talosctl gen config <cluster> https://<cp-ip>:6443${CL}"
echo -e "${TAB}3. Apply config:      ${BL}talosctl apply-config --insecure -n <ip> -f <role>.yaml${CL}"
echo -e "${TAB}4. Bootstrap (cp#1):  ${BL}talosctl bootstrap -n <ip>${CL}"
echo -e "${TAB}5. Kubeconfig:        ${BL}talosctl kubeconfig -n <ip>${CL}"
echo
echo -e "${INFO} ${HA}Installer image (for talosctl upgrade)${CL}"
echo -e "${TAB}${GN}$INSTALLER_IMAGE${CL}"
echo

if [[ "$SERIAL_CONSOLE" == "yes" ]]; then
    echo -e "${INFO} ${HA}Console Access${CL}"
    echo -e "${TAB}VGA:    ${GN}qm terminal <vmid>${CL}"
    echo -e "${TAB}Serial: ${GN}qm terminal <vmid> -iface serial0${CL}"
    echo
fi

exit 0
