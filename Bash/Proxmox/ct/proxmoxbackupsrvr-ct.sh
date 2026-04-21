#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317
# Purpose: Create a Proxmox Backup Server LXC container on Proxmox VE.
#
# Flow:
#   1. Validates host (root / PVE / arch / deps).
#   2. Wizard-driven or --defaults configuration.
#   3. Selects template + container storage, downloads Debian 13 template if needed.
#   4. Creates unprivileged (or privileged) LXC via pct create.
#   5. Starts the CT, waits for networking, registers the Proxmox PBS repo +
#      GPG key, installs proxmox-backup-server, enables the proxy service.
#
# Usage:
#   proxmoxbackupsrvr-ct.sh              # interactive wizard
#   proxmoxbackupsrvr-ct.sh --defaults   # non-interactive with sensible defaults
#   proxmoxbackupsrvr-ct.sh --help       # show usage
#
# Dependencies on host: whiptail, pveversion, pvesh, pvesm, pct, pveam,
#                       curl, wget, awk, sed, numfmt, openssl

set -Eeuo pipefail

#################################################################################
# Constants                                                                      #
#################################################################################

# PBS 4.x ships as a Debian 13 (Trixie) package — keep the template locked to
# that so the repo signing key and suite name match.
PBS_OS_TYPE="debian"
PBS_OS_VERSION="13"
PBS_REPO_LINE_TYPE="Types: deb"
PBS_REPO_URI="http://download.proxmox.com/debian/pbs"
PBS_REPO_SUITE="trixie"
PBS_REPO_COMPONENT="pbs-no-subscription"
PBS_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
PBS_KEY_SHA256="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
PBS_KEY_DST="/usr/share/keyrings/proxmox-archive-keyring.gpg"
PBS_SOURCES_FILE="/etc/apt/sources.list.d/proxmox.sources"
PBS_ENTERPRISE_SOURCES="/etc/apt/sources.list.d/pbs-enterprise.sources"

# CT ID range
STARTING_CT_ID=500

# Network defaults
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MTU="1500"

# Resource defaults (PBS 4.x is Rust-heavy; give it breathing room)
DEFAULT_CORES=2
DEFAULT_RAM_MIB=2048
DEFAULT_DISK_GB=12

# CLI flags
NON_INTERACTIVE="no"

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

function header_info() {
    clear
    cat <<"EOF"
  ____  ____ ____      ____ _____
 |  _ \| __ ) ___|    / ___|_   _|
 | |_) |  _ \___ \   | |     | |
 |  __/| |_) |__) |  | |___  | |
 |_|   |____/____/    \____| |_|

    P R O X M O X   B A C K U P   S E R V E R   L X C
EOF
}

#################################################################################
# Global state                                                                   #
#################################################################################

CTID=""
HN=""
CT_TYPE="1"              # 1 = unprivileged, 0 = privileged
DISK_SIZE_GB=""
CORE_COUNT=""
RAM_SIZE_MIB=""
BRG=""
NET=""
GATE=""
IPV6_METHOD=""
IPV6_ADDR=""
IPV6_GATE=""
SEARCHDOMAIN=""
NAMESERVER=""
MAC=""
VLAN=""
MTU=""
TAGS=""
VERBOSE="no"
ROOT_PW=""
CT_TIMEZONE=""
ENABLE_FUSE="no"
ENABLE_NESTING="1"       # Required for modern systemd (Debian 13)
ENABLE_KEYCTL=""
PROTECT_CT="no"
START_CT="yes"
SSH_ENABLE="no"
SSH_KEY=""

TEMPLATE_STORAGE=""
CONTAINER_STORAGE=""
TEMPLATE=""
TEMPLATE_PATH=""

# PBS datastore setup (optional)
INIT_DATASTORE="no"
DATASTORE_NAME=""
DATASTORE_PATH=""

#################################################################################
# Error Handling & Cleanup                                                       #
#################################################################################

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
    cleanup_ct
    exit "$exit_code"
}

function cleanup_ct() {
    if [[ -n "${CTID:-}" ]] && pct status "$CTID" &>/dev/null; then
        local state
        state=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
        if [[ "$state" == "running" || "$state" == "stopped" ]]; then
            msg_info "Cleaning up CT $CTID"
            if [[ "$state" == "running" ]]; then
                pct stop "$CTID" --skiplock 1 &>/dev/null || true
            fi
            sleep 2
            pct destroy "$CTID" --purge 1 &>/dev/null || true
            msg_ok "Cleaned up partially-created CT $CTID"
        fi
    fi
}

function exit_script() {
    clear
    echo -e "User exited script.\n"
    exit 1
}

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap 'exit 130' SIGINT
trap 'exit 143' SIGTERM
trap 'exit 129' SIGHUP

#################################################################################
# CLI / Help                                                                     #
#################################################################################

function usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Create a Proxmox Backup Server LXC container in Proxmox VE.

Options:
  --defaults      Skip interactive prompts; use sensible defaults
  -h, --help      Show this help message

Environment overrides (only used with --defaults):
  CTID=<id>       Override auto-selected CT ID
  BRG=<bridge>    Override default bridge (${DEFAULT_BRIDGE})
  ROOT_PW=<pw>    Set root password (otherwise prompted / random)

Examples:
  $0                     Launch interactive wizard
  $0 --defaults          Create PBS CT non-interactively
EOF
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --defaults)  NON_INTERACTIVE="yes"; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           msg_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
}

#################################################################################
# Dependency Check                                                               #
#################################################################################

function check_dependencies() {
    local deps=(whiptail pveversion pvesh pvesm pct pveam wget curl awk sed numfmt openssl)
    declare -A pkg_map=(
        [whiptail]=whiptail
        [pveversion]=pve-manager
        [pvesh]=pve-manager
        [pvesm]=pve-manager
        [pct]=pve-container
        [pveam]=pve-manager
        [wget]=wget
        [curl]=curl
        [awk]=mawk
        [sed]=sed
        [numfmt]=coreutils
        [openssl]=openssl
    )

    local missing_pkgs=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("${pkg_map[$cmd]:-$cmd}")
        fi
    done

    if ((${#missing_pkgs[@]} == 0)); then
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
        if ! whiptail --backtitle "Proxmox VE PBS CT Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's recommended to use the Proxmox shell instead of SSH.\nSSH can cause issues with interactive elements.\n\nContinue anyway?" 12 62; then
            exit_script
        fi
    fi
}

#################################################################################
# CT ID / Hostname / Validation Helpers                                          #
#################################################################################

function validate_ct_id() {
    local id="$1"
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    ((id >= 100)) || return 1
    # Cluster-wide
    if command -v pvesh &>/dev/null; then
        local ids
        ids=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
              | grep -oP '"vmid":\s*\K[0-9]+' 2>/dev/null || true)
        if [[ -n "$ids" ]] && echo "$ids" | grep -qw "$id"; then
            return 1
        fi
    fi
    # Local config
    [[ -f "/etc/pve/qemu-server/${id}.conf" || -f "/etc/pve/lxc/${id}.conf" ]] && return 1
    # Every node in the cluster
    if [[ -d /etc/pve/nodes ]]; then
        for d in /etc/pve/nodes/*/; do
            [[ -f "${d}qemu-server/${id}.conf" || -f "${d}lxc/${id}.conf" ]] && return 1
        done
    fi
    # LVM volume collision
    if command -v lvs &>/dev/null && \
       lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${id}($|[-_])"; then
        return 1
    fi
    return 0
}

function get_valid_ct_id() {
    local id
    id=$(pvesh get /cluster/nextid 2>/dev/null || echo "$STARTING_CT_ID")
    ((id < STARTING_CT_ID)) && id=$STARTING_CT_ID
    local tries=0
    while ! validate_ct_id "$id"; do
        ((id++))
        ((++tries > 1000)) && { msg_error "Could not find a free CT ID"; exit 1; }
    done
    echo "$id"
}

function validate_hostname() {
    local hn="$1"
    [[ -n "$hn" && ${#hn} -le 253 ]] || return 1
    local IFS='.'; read -ra labels <<<"$hn"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ || "$label" =~ ^[a-z0-9]$ ]] || return 1
    done
    return 0
}

function validate_mac() {
    local m="$1"
    [[ -z "$m" ]] && return 0
    [[ "$m" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

function validate_vlan() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    [[ "$v" =~ ^[0-9]+$ ]] && ((v >= 1 && v <= 4094))
}

function validate_mtu() {
    local m="$1"
    [[ -z "$m" ]] && return 0
    [[ "$m" =~ ^[0-9]+$ ]] && ((m >= 576 && m <= 65535))
}

function validate_ipv4_cidr() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do ((o <= 255)) || return 1; done
    local cidr="${BASH_REMATCH[5]}"
    ((cidr >= 1 && cidr <= 32))
}

function validate_ipv4() {
    local ip="$1"
    [[ -z "$ip" ]] && return 0
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1:4}"; do ((o <= 255)) || return 1; done
    return 0
}

function validate_gateway_in_subnet() {
    local static_ip="$1" gw="$2"
    [[ -z "$static_ip" || -z "$gw" ]] && return 0
    local ip="${static_ip%%/*}" cidr="${static_ip##*/}"
    ((cidr >= 31)) && return 0
    local mask=$((0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF))
    local IFS='.'
    read -r i1 i2 i3 i4 <<<"$ip"
    read -r g1 g2 g3 g4 <<<"$gw"
    local ip_int=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
    local gw_int=$(( (g1 << 24) + (g2 << 16) + (g3 << 8) + g4 ))
    (( (ip_int & mask) == (gw_int & mask) ))
}

function validate_ipv6() {
    local ip="$1"
    [[ -z "$ip" ]] && return 0
    local addr="${ip%%/*}" cidr="${ip##*/}"
    if [[ "$ip" == */* ]]; then
        [[ "$cidr" =~ ^[0-9]+$ ]] && ((cidr >= 1 && cidr <= 128)) || return 1
    fi
    [[ "$addr" =~ ^[0-9a-fA-F:]+$ && "$addr" == *:* ]] || return 1
    [[ "$addr" == *::*::* ]] && return 1
    local IFS=':'; local -a segs
    read -ra segs <<<"$addr"
    for s in "${segs[@]}"; do
        ((${#s} <= 4)) || return 1
    done
    return 0
}

function validate_timezone() {
    local tz="$1"
    [[ -z "$tz" || "$tz" == "host" ]] && return 0
    [[ -f "/usr/share/zoneinfo/$tz" ]]
}

function validate_tags() {
    local t="$1"
    [[ -z "$t" ]] && return 0
    [[ "$t" =~ ^[a-zA-Z0-9_\;-]+$ ]]
}

function generate_mac() {
    local hex
    hex=$(openssl rand -hex 5)
    echo "02:$(echo "$hex" | sed 's/\(..\)/\1:/g; s/.$//' | tr '[:lower:]' '[:upper:]')"
}

function get_available_bridges() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | sort -u
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
    if whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "BRIDGE NOT FOUND" \
        --yesno "Bridge '$bridge' does not exist.\n\nCreate it now (plain, no ports)?" 10 60; then
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
# Storage Selection                                                              #
#################################################################################

function _storage_menu_items() {
    local content="$1"
    local -a items=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^Name ]] && continue
        local tag stype free
        tag=$(echo "$line"   | awk '{print $1}')
        stype=$(echo "$line" | awk '{print $2}')
        free=$(echo "$line"  | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f \
                              | awk '{printf "%9sB", $6}')
        [[ -z "$tag" ]] && continue
        items+=("$tag" "Type: $stype, Free: $free")
    done < <(pvesm status -content "$content" 2>/dev/null)
    printf '%s\n' "${items[@]}"
}

function select_template_storage() {
    local -a items=()
    mapfile -t items < <(_storage_menu_items vztmpl)
    if ((${#items[@]} == 0)); then
        msg_error "No storage with 'vztmpl' content configured"
        exit 1
    fi
    if ((${#items[@]} == 2)) || [[ "$NON_INTERACTIVE" == "yes" ]]; then
        TEMPLATE_STORAGE="${items[0]}"
        msg_ok "Using template storage: $TEMPLATE_STORAGE"
        return
    fi
    TEMPLATE_STORAGE=$(whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "TEMPLATE STORAGE" \
        --menu "Select storage for Debian LXC template:" 18 70 8 \
        "${items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using template storage: $TEMPLATE_STORAGE"
}

function select_container_storage() {
    local -a items=()
    mapfile -t items < <(_storage_menu_items rootdir)
    if ((${#items[@]} == 0)); then
        msg_error "No storage with 'rootdir' content configured"
        exit 1
    fi
    if ((${#items[@]} == 2)) || [[ "$NON_INTERACTIVE" == "yes" ]]; then
        CONTAINER_STORAGE="${items[0]}"
        msg_ok "Using container storage: $CONTAINER_STORAGE"
        return
    fi
    CONTAINER_STORAGE=$(whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "CONTAINER STORAGE" \
        --menu "Select storage for PBS CT rootfs:" 18 70 8 \
        "${items[@]}" 3>&1 1>&2 2>&3) || exit_script
    msg_ok "Using container storage: $CONTAINER_STORAGE"
}

#################################################################################
# Settings (Default + Advanced wizard)                                           #
#################################################################################

function default_settings() {
    CTID="${CTID:-$(get_valid_ct_id)}"
    HN="pbs-ct${CTID}"
    CT_TYPE="1"
    DISK_SIZE_GB="$DEFAULT_DISK_GB"
    CORE_COUNT="$DEFAULT_CORES"
    RAM_SIZE_MIB="$DEFAULT_RAM_MIB"
    BRG="${BRG:-$DEFAULT_BRIDGE}"
    NET="dhcp"
    GATE=""
    IPV6_METHOD="auto"
    IPV6_ADDR=""
    IPV6_GATE=""
    SEARCHDOMAIN=""
    NAMESERVER=""
    MAC=$(generate_mac)
    VLAN=""
    MTU="$DEFAULT_MTU"
    TAGS="backup;pbs"
    VERBOSE="no"
    ENABLE_FUSE="no"
    ENABLE_NESTING="1"
    ENABLE_KEYCTL="1"       # Forced on for unprivileged + Debian 13 systemd
    PROTECT_CT="no"
    START_CT="yes"
    SSH_ENABLE="no"
    SSH_KEY=""
    # Timezone: match host
    if command -v timedatectl &>/dev/null; then
        CT_TIMEZONE=$(timedatectl show --value --property=Timezone 2>/dev/null || echo "")
    elif [[ -f /etc/timezone ]]; then
        CT_TIMEZONE=$(cat /etc/timezone)
    fi
    [[ "$CT_TIMEZONE" == Etc/* ]] && CT_TIMEZONE="host"
    [[ -z "$CT_TIMEZONE" ]] && CT_TIMEZONE="host"

    # Root password: use env override, or generate a random one we'll print
    if [[ -z "${ROOT_PW:-}" ]]; then
        ROOT_PW=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)
        ROOT_PW_GENERATED="yes"
    else
        ROOT_PW_GENERATED="no"
    fi

    msg_ok "Default settings applied"
}

function advanced_settings() {
    local bt="Proxmox VE PBS CT Install Script"
    local STEP=1 MAX_STEP=16

    local _ctid _hn _ctype="1" _disk="$DEFAULT_DISK_GB" _cpu="$DEFAULT_CORES"
    local _ram="$DEFAULT_RAM_MIB" _bridge="$DEFAULT_BRIDGE" _net="dhcp" _gate=""
    local _ipv6="auto" _ipv6_addr="" _ipv6_gw="" _sd="" _ns="" _mac="" _vlan=""
    local _mtu="" _tags="backup;pbs" _tz="" _pw="" _pw_disp="Automatic Login"
    local _fuse="no" _nesting="1" _protect="no" _verbose="no" _startct="yes"
    local _ssh="no" _ssh_key="" _init_ds="no" _ds_name="" _ds_path=""

    _ctid=$(get_valid_ct_id)
    _hn="pbs-ct${_ctid}"

    # Host TZ default
    if command -v timedatectl &>/dev/null; then
        _tz=$(timedatectl show --value --property=Timezone 2>/dev/null || echo "")
    elif [[ -f /etc/timezone ]]; then
        _tz=$(cat /etc/timezone)
    fi
    [[ "$_tz" == Etc/* ]] && _tz="host"

    local bridges=()
    mapfile -t bridges < <(get_available_bridges)

    while (( STEP <= MAX_STEP )); do
        case $STEP in
        1)
            # CT TYPE
            local on1="ON" on0="OFF"
            [[ "$_ctype" == "0" ]] && { on1="OFF"; on0="ON"; }
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "CONTAINER TYPE" --ok-button "Next" --cancel-button "Exit" \
                --radiolist "\nChoose container type:" 12 60 2 \
                "1" "Unprivileged (recommended)" "$on1" \
                "0" "Privileged" "$on0" \
                3>&1 1>&2 2>&3); then
                [[ -n "$result" ]] && _ctype="$result"
                ((STEP++))
            else
                exit_script
            fi
            ;;
        2)
            # ROOT PASSWORD
            if pw1=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "ROOT PASSWORD" --ok-button "Next" --cancel-button "Back" \
                --passwordbox "\nSet root password (blank = automatic login)" 12 60 \
                3>&1 1>&2 2>&3); then
                if [[ -z "$pw1" ]]; then
                    _pw=""; _pw_disp="Automatic Login"
                    ((STEP++))
                elif ((${#pw1} < 5)); then
                    whiptail --msgbox "Password must be at least 5 characters." 8 58
                else
                    if pw2=$(whiptail --backtitle "$bt" --title "CONFIRM PASSWORD" \
                        --passwordbox "\nRe-enter root password" 10 58 \
                        3>&1 1>&2 2>&3); then
                        if [[ "$pw1" == "$pw2" ]]; then
                            _pw="$pw1"; _pw_disp="********"
                            ((STEP++))
                        else
                            whiptail --msgbox "Passwords do not match." 8 58
                        fi
                    fi
                fi
            else
                ((STEP--))
            fi
            ;;
        3)
            # CT ID
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "CONTAINER ID" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nSet Container ID" 10 58 "$_ctid" \
                3>&1 1>&2 2>&3); then
                local id="${result:-$_ctid}"
                if ! [[ "$id" =~ ^[0-9]+$ ]]; then
                    whiptail --msgbox "ID must be numeric." 8 58
                elif ! validate_ct_id "$id"; then
                    if whiptail --title "ID IN USE" \
                        --yesno "CT ID $id already taken.\nUse next free ID ($(get_valid_ct_id))?" 9 58; then
                        _ctid=$(get_valid_ct_id)
                        ((STEP++))
                    fi
                else
                    _ctid="$id"; _hn="pbs-ct${_ctid}"
                    ((STEP++))
                fi
            else
                ((STEP--))
            fi
            ;;
        4)
            # HOSTNAME
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "HOSTNAME" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nSet hostname (or FQDN)" 10 58 "$_hn" \
                3>&1 1>&2 2>&3); then
                local hn_t="${result:-$_hn}"
                hn_t=$(echo "${hn_t,,}" | tr -d ' ')
                if validate_hostname "$hn_t"; then
                    _hn="$hn_t"; ((STEP++))
                else
                    whiptail --msgbox "Invalid hostname.\nRFC 1123: lowercase, digits, hyphens, dots." 10 60
                fi
            else
                ((STEP--))
            fi
            ;;
        5)
            # DISK SIZE
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "DISK SIZE" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nRootfs disk size in GB\n\n(PBS metadata lives here; datastore is separate)" 12 60 "$_disk" \
                3>&1 1>&2 2>&3); then
                if [[ "$result" =~ ^[1-9][0-9]*$ ]]; then
                    _disk="$result"
                    ((STEP++))
                else
                    whiptail --msgbox "Disk size must be a positive integer." 8 58
                fi
            else
                ((STEP--))
            fi
            ;;
        6)
            # CPU CORES
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "CPU CORES" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nCPU cores" 10 58 "$_cpu" \
                3>&1 1>&2 2>&3); then
                if [[ "$result" =~ ^[1-9][0-9]*$ ]]; then
                    _cpu="$result"
                    ((STEP++))
                else
                    whiptail --msgbox "Cores must be a positive integer." 8 58
                fi
            else
                ((STEP--))
            fi
            ;;
        7)
            # RAM
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "RAM (MiB)" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nRAM in MiB" 10 58 "$_ram" \
                3>&1 1>&2 2>&3); then
                if [[ "$result" =~ ^[1-9][0-9]*$ ]]; then
                    _ram="$result"
                    ((STEP++))
                else
                    whiptail --msgbox "RAM must be a positive integer." 8 58
                fi
            else
                ((STEP--))
            fi
            ;;
        8)
            # BRIDGE
            if ((${#bridges[@]} > 0)); then
                local br_items=()
                for b in "${bridges[@]}"; do br_items+=("$b" "existing bridge"); done
                br_items+=("__custom__" "Enter a different name")
                if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                    --title "BRIDGE" --ok-button "Next" --cancel-button "Back" \
                    --menu "\nSelect bridge" 18 60 10 \
                    "${br_items[@]}" 3>&1 1>&2 2>&3); then
                    if [[ "$result" == "__custom__" ]]; then
                        result=$(whiptail --inputbox "Bridge name" 8 58 "$_bridge" 3>&1 1>&2 2>&3) || continue
                    fi
                    _bridge="$result"; ((STEP++))
                else
                    ((STEP--))
                fi
            else
                if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                    --title "BRIDGE" --inputbox "Bridge name" 8 58 "$_bridge" \
                    3>&1 1>&2 2>&3); then
                    _bridge="$result"; ((STEP++))
                else
                    ((STEP--))
                fi
            fi
            ;;
        9)
            # IPv4 MODE
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "IPv4" --ok-button "Next" --cancel-button "Back" \
                --menu "\nIPv4 assignment" 12 60 2 \
                "dhcp"   "Automatic (DHCP, recommended)" \
                "static" "Static IP + Gateway" \
                3>&1 1>&2 2>&3); then
                if [[ "$result" == "static" ]]; then
                    local sip gw
                    sip=$(whiptail --inputbox "Static IPv4 CIDR (e.g. 192.168.1.50/24)" 10 60 "" --title "Static IPv4" 3>&1 1>&2 2>&3) || continue
                    if ! validate_ipv4_cidr "$sip"; then
                        whiptail --msgbox "Invalid IPv4/CIDR format." 8 58; continue
                    fi
                    gw=$(whiptail --inputbox "Gateway IPv4 address" 10 60 "" --title "Gateway" 3>&1 1>&2 2>&3) || continue
                    if ! validate_ipv4 "$gw"; then
                        whiptail --msgbox "Invalid gateway IPv4." 8 58; continue
                    fi
                    if ! validate_gateway_in_subnet "$sip" "$gw"; then
                        whiptail --msgbox "Gateway not in same subnet as IP." 8 58; continue
                    fi
                    _net="$sip"; _gate="$gw"
                else
                    _net="dhcp"; _gate=""
                fi
                ((STEP++))
            else
                ((STEP--))
            fi
            ;;
        10)
            # IPv6 MODE
            if result=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "IPv6" --ok-button "Next" --cancel-button "Back" \
                --menu "\nIPv6 assignment" 14 60 4 \
                "auto"   "SLAAC (recommended)" \
                "dhcp"   "DHCPv6" \
                "static" "Static IPv6 + Gateway" \
                "none"   "Disabled" \
                3>&1 1>&2 2>&3); then
                _ipv6="$result"
                if [[ "$_ipv6" == "static" ]]; then
                    local v6 v6gw
                    v6=$(whiptail --inputbox "IPv6 CIDR (e.g. 2001:db8::1/64)" 10 60 "" --title "Static IPv6" 3>&1 1>&2 2>&3) || continue
                    if ! validate_ipv6 "$v6"; then
                        whiptail --msgbox "Invalid IPv6." 8 58; continue
                    fi
                    v6gw=$(whiptail --inputbox "IPv6 gateway (blank for none)" 10 60 "" --title "IPv6 Gateway" 3>&1 1>&2 2>&3) || v6gw=""
                    if [[ -n "$v6gw" ]] && ! validate_ipv6 "$v6gw"; then
                        whiptail --msgbox "Invalid IPv6 gateway." 8 58; continue
                    fi
                    _ipv6_addr="$v6"; _ipv6_gw="$v6gw"
                else
                    _ipv6_addr=""; _ipv6_gw=""
                fi
                ((STEP++))
            else
                ((STEP--))
            fi
            ;;
        11)
            # DNS / MTU / VLAN / MAC
            _sd=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "DNS Search Domain" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nSearch domain (blank = host)" 10 58 "$_sd" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            _ns=$(whiptail --backtitle "$bt" --title "DNS Servers" --inputbox \
                "\nDNS server(s), space-separated (blank = host)" 10 60 "$_ns" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            _mtu=$(whiptail --backtitle "$bt" --title "MTU" --inputbox \
                "\nMTU (blank = 1500, common: 1500, 9000)" 10 58 "$_mtu" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            if ! validate_mtu "$_mtu"; then
                whiptail --msgbox "Invalid MTU (576-65535)." 8 58; continue
            fi
            _vlan=$(whiptail --backtitle "$bt" --title "VLAN" --inputbox \
                "\nVLAN tag (blank = none, 1-4094)" 10 58 "$_vlan" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            if ! validate_vlan "$_vlan"; then
                whiptail --msgbox "Invalid VLAN tag." 8 58; continue
            fi
            _mac=$(whiptail --backtitle "$bt" --title "MAC" --inputbox \
                "\nMAC address (blank = auto-generated)" 10 58 "$_mac" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            if ! validate_mac "$_mac"; then
                whiptail --msgbox "Invalid MAC format." 8 58; continue
            fi
            ((STEP++))
            ;;
        12)
            # TIMEZONE + TAGS
            _tz=$(whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "Timezone" --ok-button "Next" --cancel-button "Back" \
                --inputbox "\nContainer timezone (e.g. America/New_York, 'host' to inherit)" 12 60 "$_tz" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            [[ "$_tz" == Etc/* ]] && _tz="host"
            if ! validate_timezone "$_tz"; then
                whiptail --msgbox "Invalid timezone: $_tz" 8 58; continue
            fi
            _tags=$(whiptail --backtitle "$bt" --title "Tags" --inputbox \
                "\nTags (semicolon-separated)" 10 58 "$_tags" \
                3>&1 1>&2 2>&3) || { ((STEP--)); continue; }
            if ! validate_tags "$_tags"; then
                whiptail --msgbox "Invalid tag chars (only alphanum, -, _, ;)." 8 58; continue
            fi
            ((STEP++))
            ;;
        13)
            # FEATURES: fuse, nesting, protection
            _fuse="no"
            if whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "FUSE" --defaultno \
                --yesno "Enable FUSE? (needed for fuse-mounted datastores)" 8 62; then
                _fuse="yes"
            fi
            _nesting="1"
            if ! whiptail --title "NESTING" \
                --yesno "Enable nesting?\n\nRequired for Debian 13 systemd and nested services." 10 62; then
                _nesting="0"
                whiptail --msgbox "⚠ Warning: PBS on Debian 13 typically requires nesting.\n\nContinuing, but services may fail to start." 10 66
            fi
            _protect="no"
            if whiptail --title "PROTECTION" --defaultno \
                --yesno "Enable container protection (prevent accidental delete)?" 8 62; then
                _protect="yes"
            fi
            ((STEP++))
            ;;
        14)
            # SSH
            _ssh="no"; _ssh_key=""
            if whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "SSH" --defaultno \
                --yesno "Enable root SSH into the CT?" 8 58; then
                _ssh="yes"
                # Try to find host root keys
                local key_default=""
                if [[ -r /root/.ssh/authorized_keys ]]; then
                    key_default=$(head -n1 /root/.ssh/authorized_keys 2>/dev/null | tr -d '\r')
                fi
                _ssh_key=$(whiptail --backtitle "$bt" \
                    --title "SSH PUBLIC KEY" \
                    --inputbox "\nPaste an SSH public key (blank to just enable password auth)" 12 76 "$key_default" \
                    3>&1 1>&2 2>&3) || true
            fi
            ((STEP++))
            ;;
        15)
            # OPTIONAL DATASTORE INIT
            _init_ds="no"; _ds_name=""; _ds_path=""
            if whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "PBS DATASTORE" \
                --yesno "Initialise a datastore inside the CT after install?\n\nThis creates a directory and registers it in PBS." 10 66; then
                _init_ds="yes"
                _ds_name=$(whiptail --inputbox "Datastore name" 8 58 "local-store" --title "Datastore" 3>&1 1>&2 2>&3) || _init_ds="no"
                if [[ "$_init_ds" == "yes" ]]; then
                    _ds_path=$(whiptail --inputbox "Datastore path (inside CT)" 10 60 "/var/lib/pbs/local-store" --title "Datastore path" 3>&1 1>&2 2>&3) || _init_ds="no"
                fi
            fi
            ((STEP++))
            ;;
        16)
            # VERBOSE + CONFIRM
            if whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "VERBOSE" --defaultno \
                --yesno "Enable verbose output during install?" 8 58; then
                _verbose="yes"
            else
                _verbose="no"
            fi
            if whiptail --backtitle "$bt" --title "START CT" \
                --yesno "Start the CT automatically after creation?" 8 58; then
                _startct="yes"
            else
                _startct="no"
            fi
            local ctype_label="Unprivileged"
            [[ "$_ctype" == "0" ]] && ctype_label="Privileged"
            local nesting_label="Enabled"
            [[ "$_nesting" != "1" ]] && nesting_label="Disabled"
            local ds_label="none"
            [[ "$_init_ds" == "yes" ]] && ds_label="$_ds_name @ $_ds_path"
            local summary
            summary="Container Type:  ${ctype_label}
CT ID:           $_ctid
Hostname:        $_hn
Root password:   $_pw_disp
Disk:            ${_disk} GB
CPU:             $_cpu cores
RAM:             $_ram MiB
Bridge:          $_bridge
IPv4:            $_net${_gate:+  gw=$_gate}
IPv6:            $_ipv6${_ipv6_addr:+  $_ipv6_addr}
MTU/VLAN/MAC:    ${_mtu:-1500}/${_vlan:-none}/${_mac:-auto}
Timezone:        $_tz
Tags:            $_tags
FUSE:            $_fuse
Nesting:         ${nesting_label}
Protection:      $_protect
SSH:             $_ssh
Datastore:       ${ds_label}"
            if whiptail --backtitle "$bt [Step $STEP/$MAX_STEP]" \
                --title "CONFIRM" --ok-button "Create CT" --cancel-button "Back" \
                --yesno "${summary}\n\nProceed?" 28 72; then
                ((STEP++))
            else
                ((STEP--))
            fi
            ;;
        esac
    done

    # Commit choices to globals
    CTID="$_ctid"
    HN="$_hn"
    CT_TYPE="$_ctype"
    DISK_SIZE_GB="$_disk"
    CORE_COUNT="$_cpu"
    RAM_SIZE_MIB="$_ram"
    BRG="$_bridge"
    NET="$_net"
    GATE="$_gate"
    IPV6_METHOD="$_ipv6"
    IPV6_ADDR="$_ipv6_addr"
    IPV6_GATE="$_ipv6_gw"
    SEARCHDOMAIN="$_sd"
    NAMESERVER="$_ns"
    MAC="${_mac:-$(generate_mac)}"
    VLAN="$_vlan"
    MTU="${_mtu:-$DEFAULT_MTU}"
    TAGS="$_tags"
    CT_TIMEZONE="$_tz"
    ENABLE_FUSE="$_fuse"
    ENABLE_NESTING="$_nesting"
    ENABLE_KEYCTL="1"        # Required for unprivileged + Docker/systemd; safe when privileged too
    PROTECT_CT="$_protect"
    VERBOSE="$_verbose"
    START_CT="$_startct"
    SSH_ENABLE="$_ssh"
    SSH_KEY="$_ssh_key"
    INIT_DATASTORE="$_init_ds"
    DATASTORE_NAME="$_ds_name"
    DATASTORE_PATH="$_ds_path"
    if [[ -n "$_pw" ]]; then
        ROOT_PW="$_pw"
        ROOT_PW_GENERATED="no"
    else
        ROOT_PW=""
        ROOT_PW_GENERATED="no"
    fi
    msg_ok "Advanced settings configured"
}

function start_script() {
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        default_settings
        return
    fi
    if whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "SETTINGS" \
        --yesno "Use default settings?\n\n(Select No for the advanced 16-step wizard)" \
        --defaultno 10 60; then
        default_settings
    else
        advanced_settings
    fi
}

#################################################################################
# Template Handling                                                              #
#################################################################################

function find_or_download_template() {
    msg_info "Updating PVE appliance catalog"
    if command -v timeout &>/dev/null; then
        timeout 30 pveam update >/dev/null 2>&1 || msg_warn "pveam update timed out — continuing with cached catalog"
    else
        pveam update >/dev/null 2>&1 || msg_warn "pveam update failed — continuing with cached catalog"
    fi
    msg_ok "Catalog refreshed"

    # Look for a locally downloaded template first
    msg_info "Looking for existing ${PBS_OS_TYPE}-${PBS_OS_VERSION} template"
    local local_tpl
    local_tpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk -v os="$PBS_OS_TYPE" -v ver="$PBS_OS_VERSION" '
            $1 ~ ("/" os "-" ver "-standard_") {print $1}' \
        | sed 's|.*/||' | sort -V | tail -n1)

    if [[ -n "$local_tpl" ]]; then
        TEMPLATE="$local_tpl"
        msg_ok "Found local template: $TEMPLATE"
    else
        msg_info "Finding latest ${PBS_OS_TYPE}-${PBS_OS_VERSION} template online"
        local online_tpl
        online_tpl=$(pveam available -section system 2>/dev/null \
            | awk -v os="$PBS_OS_TYPE" -v ver="$PBS_OS_VERSION" '
                $2 ~ ("^" os "-" ver "-standard_") {print $2}' \
            | sort -V | tail -n1)
        if [[ -z "$online_tpl" ]]; then
            msg_error "No ${PBS_OS_TYPE} ${PBS_OS_VERSION} template available in pveam catalog"
            exit 1
        fi
        msg_ok "Latest online template: $online_tpl"
        msg_info "Downloading $online_tpl"
        if ! pveam download "$TEMPLATE_STORAGE" "$online_tpl" &>"/tmp/pveam-${online_tpl}.log"; then
            cat "/tmp/pveam-${online_tpl}.log" >&2
            msg_error "Template download failed"
            exit 1
        fi
        TEMPLATE="$online_tpl"
        msg_ok "Downloaded $TEMPLATE"
    fi

    TEMPLATE_PATH=$(pvesm path "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" 2>/dev/null || true)
    [[ -z "$TEMPLATE_PATH" ]] && TEMPLATE_PATH="/var/lib/vz/template/cache/${TEMPLATE}"

    if [[ ! -s "$TEMPLATE_PATH" ]]; then
        msg_error "Template file not found after download: $TEMPLATE_PATH"
        exit 1
    fi
}

#################################################################################
# Container Creation                                                             #
#################################################################################

function build_net_string() {
    local s="name=eth0,bridge=${BRG}"
    [[ -n "$MAC"  ]] && s+=",hwaddr=${MAC}"
    s+=",ip=${NET}"
    [[ -n "$GATE" ]] && s+=",gw=${GATE}"
    [[ -n "$VLAN" ]] && s+=",tag=${VLAN}"
    [[ -n "$MTU"  && "$MTU" != "$DEFAULT_MTU" ]] && s+=",mtu=${MTU}"
    case "$IPV6_METHOD" in
        auto)   s+=",ip6=auto" ;;
        dhcp)   s+=",ip6=dhcp" ;;
        static)
            if [[ -n "$IPV6_ADDR" ]]; then
                s+=",ip6=${IPV6_ADDR}"
                [[ -n "$IPV6_GATE" ]] && s+=",gw6=${IPV6_GATE}"
            fi
            ;;
        none|*) : ;;
    esac
    echo "$s"
}

function build_features_string() {
    local feats=""
    [[ "$ENABLE_NESTING" == "1" ]] && feats="nesting=1"
    if [[ "$CT_TYPE" == "1" && "$ENABLE_KEYCTL" == "1" ]]; then
        feats+="${feats:+,}keyctl=1"
    fi
    if [[ "$ENABLE_FUSE" == "yes" ]]; then
        feats+="${feats:+,}fuse=1"
    fi
    echo "$feats"
}

function ensure_subids() {
    grep -q "^root:100000:65536$" /etc/subuid || echo "root:100000:65536" >> /etc/subuid
    grep -q "^root:100000:65536$" /etc/subgid || echo "root:100000:65536" >> /etc/subgid
}

function create_ct() {
    msg_info "Creating PBS CT (ID: $CTID)"

    ensure_subids

    local net_str features_str
    net_str=$(build_net_string)
    features_str=$(build_features_string)

    local -a args=(
        --hostname "$HN"
        --ostype "$PBS_OS_TYPE"
        --arch amd64
        --cores "$CORE_COUNT"
        --memory "$RAM_SIZE_MIB"
        --swap 512
        --rootfs "${CONTAINER_STORAGE}:${DISK_SIZE_GB}"
        --net0 "$net_str"
        --unprivileged "$CT_TYPE"
        --onboot 1
        --start 0
    )

    [[ -n "$features_str" ]]  && args+=(--features "$features_str")
    [[ -n "$TAGS" ]]          && args+=(--tags "$TAGS")
    [[ -n "$SEARCHDOMAIN" ]]  && args+=(--searchdomain "$SEARCHDOMAIN")
    [[ -n "$NAMESERVER"   ]]  && args+=(--nameserver   "$NAMESERVER")
    [[ -n "$ROOT_PW" ]]       && args+=(--password "$ROOT_PW")
    [[ -n "$CT_TIMEZONE" && "$CT_TIMEZONE" != "Etc/"* ]] && args+=(--timezone "$CT_TIMEZONE")
    [[ "$PROTECT_CT" == "yes" ]] && args+=(--protection 1)

    # SSH keys (multi-line safe): pct takes --ssh-public-keys <file>
    local sshkey_tmp=""
    if [[ "$SSH_ENABLE" == "yes" && -n "$SSH_KEY" ]]; then
        sshkey_tmp=$(mktemp)
        printf '%s\n' "$SSH_KEY" > "$sshkey_tmp"
        args+=(--ssh-public-keys "$sshkey_tmp")
    fi

    local log="/tmp/pct-create-${CTID}.log"
    if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${args[@]}" &>"$log"; then
        cat "$log" >&2
        [[ -n "$sshkey_tmp" && -f "$sshkey_tmp" ]] && rm -f "$sshkey_tmp"
        msg_error "pct create failed — see $log"
        exit 1
    fi
    [[ -n "$sshkey_tmp" && -f "$sshkey_tmp" ]] && rm -f "$sshkey_tmp"

    msg_ok "CT $CTID created"
}

#################################################################################
# Container Start + Network Wait                                                  #
#################################################################################

function start_ct() {
    msg_info "Starting CT $CTID"
    pct start "$CTID"
    local timeout=15
    while ((timeout > 0)) && ! pct status "$CTID" | grep -q "status: running"; do
        sleep 1; ((timeout--))
    done
    if ! pct status "$CTID" | grep -q "status: running"; then
        msg_error "CT failed to reach running state"
        exit 1
    fi
    msg_ok "CT is running"
}

function wait_for_network() {
    msg_info "Waiting for CT networking"
    local ip=""
    for i in {1..60}; do
        ip=$(pct exec "$CTID" -- ip -4 addr show dev eth0 2>/dev/null \
             | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        [[ -z "$ip" ]] && ip=$(pct exec "$CTID" -- ip -6 addr show dev eth0 scope global 2>/dev/null \
             | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n1)
        [[ -n "$ip" ]] && break
        if ((i <= 20));    then sleep 1
        elif ((i <= 40));  then sleep 2
        else                    sleep 3
        fi
    done
    if [[ -z "$ip" ]]; then
        msg_error "CT never got an IP on eth0 after 60 attempts"
        msg_warn "Check bridge ${BRG}, DHCP, or static IP settings"
        exit 1
    fi
    msg_ok "CT IP: $ip"

    # Quick connectivity test (non-fatal)
    if pct exec "$CTID" -- sh -c 'ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1'; then
        msg_ok "CT has outbound connectivity"
    else
        msg_warn "CT has an IP but outbound ping failed — DNS/gateway may be misconfigured"
    fi
}

#################################################################################
# PBS Installation Inside CT                                                     #
#################################################################################

function run_in_ct() {
    # Pipes a heredoc-style script into the container as root.
    # Usage: run_in_ct <<'EOF' ... EOF
    pct exec "$CTID" -- bash -lc 'cat >/tmp/_runner.sh && bash /tmp/_runner.sh && rm -f /tmp/_runner.sh'
}

function install_pbs_in_ct() {
    msg_info "Preparing CT for PBS install (DNS / hostname)"
    # Ensure a sane /etc/hosts so `hostname -f` works before the PBS GUI installs.
    local short_hn="${HN%%.*}"
    local ip_line=""
    if [[ "$NET" != "dhcp" ]]; then
        ip_line="${NET%%/*}"
    fi

    run_in_ct <<EOF || { msg_error "DNS/hostname prep failed"; exit 1; }
set -e
# Ensure hostname file matches
echo "${short_hn}" > /etc/hostname
hostname ${short_hn}

# Reset /etc/hosts to a known-good state
cat > /etc/hosts <<'HOSTS'
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

# Add hostname line. Use static IP if we have one, otherwise 127.0.1.1 (Debian convention).
if [ -n "${ip_line}" ]; then
    echo "${ip_line}   ${HN} ${short_hn}" >> /etc/hosts
else
    echo "127.0.1.1   ${HN} ${short_hn}" >> /etc/hosts
fi

# Make sure we can actually resolve things before apt-get update
if ! getent hosts download.proxmox.com >/dev/null 2>&1; then
    echo 'nameserver 1.1.1.1'  >  /etc/resolv.conf
    echo 'nameserver 8.8.8.8'  >> /etc/resolv.conf
fi
EOF
    msg_ok "CT hostname/DNS prepared"

    msg_info "Installing PBS prerequisites (wget, gnupg, ca-certificates)"
    run_in_ct <<'EOF' || { msg_error "Prereq install failed"; exit 1; }
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends wget gnupg ca-certificates curl
EOF
    msg_ok "Prereqs installed"

    msg_info "Installing Proxmox archive keyring"
    run_in_ct <<EOF || { msg_error "Keyring install failed"; exit 1; }
set -e
wget -q "${PBS_KEY_URL}" -O "${PBS_KEY_DST}"
actual=\$(sha256sum "${PBS_KEY_DST}" | awk '{print \$1}')
if [ "\$actual" != "${PBS_KEY_SHA256}" ]; then
    echo "ERROR: Proxmox keyring SHA256 mismatch!"
    echo "  expected: ${PBS_KEY_SHA256}"
    echo "  got:      \$actual"
    exit 1
fi
chmod 0644 "${PBS_KEY_DST}"
EOF
    msg_ok "Keyring installed and SHA256-verified"

    msg_info "Registering PBS no-subscription repository"
    run_in_ct <<EOF || { msg_error "Repo registration failed"; exit 1; }
set -e
mkdir -p /etc/apt/sources.list.d
cat > "${PBS_SOURCES_FILE}" <<SRCS
${PBS_REPO_LINE_TYPE}
URIs: ${PBS_REPO_URI}
Suites: ${PBS_REPO_SUITE}
Components: ${PBS_REPO_COMPONENT}
Signed-By: ${PBS_KEY_DST}
SRCS

# If the template happened to ship an enterprise repo, disable it to avoid 401s.
if [ -f "${PBS_ENTERPRISE_SOURCES}" ]; then
    if ! grep -q '^Enabled:' "${PBS_ENTERPRISE_SOURCES}"; then
        echo 'Enabled: false' >> "${PBS_ENTERPRISE_SOURCES}"
    else
        sed -i 's/^Enabled:.*/Enabled: false/' "${PBS_ENTERPRISE_SOURCES}"
    fi
fi
EOF
    msg_ok "Repository registered"

    msg_info "Installing proxmox-backup-server (this can take several minutes)"
    local pbs_log="/tmp/pbs-install-${CTID}.log"
    # shellcheck disable=SC2024
    pct exec "$CTID" -- bash -lc '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y proxmox-backup-server
    ' &>"$pbs_log" || {
        cat "$pbs_log" >&2
        msg_error "PBS install failed — see $pbs_log inside the host"
        exit 1
    }
    msg_ok "proxmox-backup-server installed"

    msg_info "Ensuring PBS services are enabled"
    run_in_ct <<'EOF' || msg_warn "Could not verify PBS service state (continuing)"
set -e
systemctl enable --now proxmox-backup-proxy.service proxmox-backup.service 2>/dev/null || true
systemctl is-active --quiet proxmox-backup-proxy.service || systemctl start proxmox-backup-proxy.service
EOF
    msg_ok "PBS services up"
}

function initialise_datastore() {
    [[ "$INIT_DATASTORE" != "yes" ]] && return 0
    [[ -z "$DATASTORE_NAME" || -z "$DATASTORE_PATH" ]] && return 0

    msg_info "Initialising datastore '$DATASTORE_NAME' at $DATASTORE_PATH"
    run_in_ct <<EOF || { msg_warn "Datastore creation failed (you can create it later from the GUI)"; return 0; }
set -e
mkdir -p "${DATASTORE_PATH}"
chown backup:backup "${DATASTORE_PATH}"
# proxmox-backup-manager datastore create <name> <path>
proxmox-backup-manager datastore create "${DATASTORE_NAME}" "${DATASTORE_PATH}"
EOF
    msg_ok "Datastore '$DATASTORE_NAME' created"
}

#################################################################################
# CT Description                                                                 #
#################################################################################

function set_ct_description() {
    local created
    created=$(date +"%Y-%m-%d %H:%M:%S %Z")
    local desc
    desc=$(cat <<EOF
<div align='center'>
  <h2>Proxmox Backup Server</h2>
  <p><strong>Created:</strong> ${created}</p>
  <hr>
  <table style='text-align:left'>
    <tr><td><strong>CT ID:</strong></td><td>${CTID}</td></tr>
    <tr><td><strong>Hostname:</strong></td><td>${HN}</td></tr>
    <tr><td><strong>Type:</strong></td><td>$([[ "$CT_TYPE" == "1" ]] && echo Unprivileged || echo Privileged)</td></tr>
    <tr><td><strong>CPU:</strong></td><td>${CORE_COUNT} cores</td></tr>
    <tr><td><strong>RAM:</strong></td><td>${RAM_SIZE_MIB} MiB</td></tr>
    <tr><td><strong>Rootfs:</strong></td><td>${DISK_SIZE_GB} GB on ${CONTAINER_STORAGE}</td></tr>
    <tr><td><strong>Network:</strong></td><td>${BRG}${VLAN:+ (VLAN ${VLAN})}</td></tr>
    <tr><td><strong>IPv4:</strong></td><td>${NET}${GATE:+ gw ${GATE}}</td></tr>
    <tr><td><strong>IPv6:</strong></td><td>${IPV6_METHOD}${IPV6_ADDR:+ ${IPV6_ADDR}}</td></tr>
    <tr><td><strong>Template:</strong></td><td>${TEMPLATE}</td></tr>
  </table>
  <hr>
  <p>Web UI: <code>https://&lt;CT-IP&gt;:8007</code></p>
  <p>Default login: <code>root@pam</code></p>
</div>
EOF
)
    pct set "$CTID" --description "$desc" &>/dev/null
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

msg_ok "Initialising Proxmox Backup Server CT creation"

check_root
check_dependencies
arch_check
pve_check
ssh_check

if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ! whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "Proxmox Backup Server CT" \
        --yesno "This script will create a new PBS LXC container.

Features:
  - Debian ${PBS_OS_VERSION} (${PBS_REPO_SUITE}) base
  - Unprivileged or privileged CT
  - 16-step advanced wizard with back navigation
  - PBS no-subscription repo, SHA256-verified keyring
  - Optional datastore initialisation

Requirements:
  - Proxmox VE 8.1+ or 9.x
  - ≥ ${DEFAULT_RAM_MIB} MiB RAM available
  - ≥ ${DEFAULT_DISK_GB} GB free on target storage
  - Internet access to download.proxmox.com

Proceed?" 22 70; then
        exit_script
    fi
fi

# Collect settings
start_script

# Validate bridge
verify_bridge_exists "$BRG"

# Select storages
select_template_storage
select_container_storage

# Summary box (non-interactive still prints to console)
if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    whiptail --backtitle "Proxmox VE PBS CT Install Script" \
        --title "CONFIGURATION SUMMARY" \
        --msgbox "CT ID:    $CTID
Hostname: $HN
Type:     $([[ "$CT_TYPE" == "1" ]] && echo Unprivileged || echo Privileged)
CPU:      $CORE_COUNT cores
RAM:      $RAM_SIZE_MIB MiB
Rootfs:   $DISK_SIZE_GB GB on $CONTAINER_STORAGE
Template: (latest ${PBS_OS_TYPE}-${PBS_OS_VERSION}-standard on $TEMPLATE_STORAGE)
Bridge:   $BRG${VLAN:+ (VLAN $VLAN)}
IPv4:     $NET${GATE:+ gw $GATE}
IPv6:     $IPV6_METHOD${IPV6_ADDR:+ $IPV6_ADDR}
Tags:     $TAGS

Press Enter to proceed..." 22 70
fi

# Template acquisition
find_or_download_template

# Create and start
create_ct
start_ct
wait_for_network

# PBS install inside the CT
install_pbs_in_ct
initialise_datastore

# CT description
set_ct_description

# Final network info for the user
CT_IP=$(pct exec "$CTID" -- ip -4 addr show dev eth0 2>/dev/null \
        | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
[[ -z "$CT_IP" ]] && CT_IP=$(pct exec "$CTID" -- ip -6 addr show dev eth0 scope global 2>/dev/null \
        | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n1)

if [[ "$START_CT" != "yes" ]]; then
    msg_info "Stopping CT (user chose not to start)"
    pct shutdown "$CTID" &>/dev/null || pct stop "$CTID" &>/dev/null || true
    msg_ok "CT stopped"
fi

echo
msg_ok "Proxmox Backup Server CT setup complete!"
echo
echo -e "${INFO} ${HA}CT Information${CL}"
echo -e "${TAB}ID:         ${GN}$CTID${CL}"
echo -e "${TAB}Hostname:   ${GN}$HN${CL}"
echo -e "${TAB}Type:       ${GN}$([[ "$CT_TYPE" == "1" ]] && echo Unprivileged || echo Privileged)${CL}"
echo -e "${TAB}Storage:    ${GN}$CONTAINER_STORAGE${CL}"
echo -e "${TAB}Template:   ${GN}$TEMPLATE${CL}"
echo -e "${TAB}IP:         ${GN}${CT_IP:-unknown}${CL}"
echo -e "${TAB}MAC:        ${GN}$MAC${CL}"
echo
echo -e "${INFO} ${HA}PBS Web UI${CL}"
if [[ -n "${CT_IP:-}" ]]; then
    echo -e "${TAB}${GN}https://${CT_IP}:8007${CL}"
else
    echo -e "${TAB}${GN}https://<CT-IP>:8007${CL}"
fi
echo -e "${TAB}Login:      ${GN}root@pam${CL}"
if [[ "${ROOT_PW_GENERATED:-no}" == "yes" && -n "$ROOT_PW" ]]; then
    echo -e "${TAB}Password:   ${GN}${ROOT_PW}${CL}  ${YL}(auto-generated — save it now!)${CL}"
elif [[ -n "$ROOT_PW" ]]; then
    echo -e "${TAB}Password:   ${GN}(as configured)${CL}"
else
    echo -e "${TAB}Password:   ${YL}autologin — set one via 'pct exec $CTID -- passwd'${CL}"
fi
echo
if [[ "$INIT_DATASTORE" == "yes" ]]; then
    echo -e "${INFO} ${HA}Datastore${CL}"
    echo -e "${TAB}Name: ${GN}$DATASTORE_NAME${CL}"
    echo -e "${TAB}Path: ${GN}$DATASTORE_PATH${CL}"
    echo
fi
echo -e "${INFO} ${HA}Shell Access${CL}"
echo -e "${TAB}${GN}pct enter $CTID${CL}"
echo

exit 0
