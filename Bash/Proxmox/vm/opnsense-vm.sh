#!/usr/bin/env bash
# Purpose: Automate the creation of an OPNsense VM in Proxmox.

set -euo pipefail

#################################################################################
# ISO Download fallback settings if newest ISO cannot be automatically obtained #
#################################################################################
FALLBACK_URL="https://mirrors.ocf.berkeley.edu/opnsense/releases/24.7/OPNsense-24.7-dvd-amd64.iso.bz2"
FALLBACK_RELEASE_DATE="2024-Jul-23"  # Known release date for OPNsense 24.7

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

header_info

NEXTID=100
CL="\033[m"
GN="\033[1;92m"
RD="\033[01;31m"
DGN="\033[32m"
BGN="\033[4;92m"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

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

trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT

function msg_info() {
    echo -e "${GN}Info:${CL} $1"
}

function msg_ok() {
    echo -e "${CM} ${GN}$1${CL}"
}

function msg_error() {
    echo -e "${CROSS} ${RD}$1${CL}"
}

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
    while pvesh get /cluster/resources --type vm | grep -qw "$NEXTID"; do
        ((NEXTID++))
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
    if ! pveversion | grep -Eq "pve-manager/8.[1-3]"; then
        msg_error "This version of Proxmox Virtual Environment is not supported"
        echo -e "Requires Proxmox Virtual Environment Version 8.1 or later."
        echo -e "Exiting..."
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

function ssh_check() {
    if [[ -n "${SSH_CLIENT:+x}" ]]; then
        if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --defaultno \
            --title "SSH DETECTED" \
            --yesno "It's suggested to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
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

function default_settings() {
    check_vmid
    VMID="$NEXTID"
    FORMAT=",efitype=4m"
    MACHINE="q35"
    DISK_CACHE=""
    HN="OPNsense$VMID"
    CPU_TYPE="host"
    CORE_COUNT="2"
    RAM_SIZE="2048"
    DISK_SIZE="30G"
    EFI_DISK_SIZE="8M"

    if [ "$MANAGE_INTERFACES" = "yes" ]; then
        BRIDGE1="opnwan"
        MAC1=$(generate_mac)
        MTU1="1500"
        BRIDGE2="opnlan"
        MAC2=$(generate_mac)
        MTU2="1500"
        BRIDGE3="opnmgmt"
        MAC3=$(generate_mac)
        MTU3="1500"
    fi

    START_VM="yes"
    VM_TAG="firewall"
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
            --inputbox "INTERFACE (1/3) DEFAULT: opnwan" 8 60 "opnwan" \
            --title "INTERFACE NAME (opnwan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for opnwan" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (opnwan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU1=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for opnwan (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (opnwan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

        BRIDGE2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (2/3) DEFAULT: opnlan" 8 60 "opnlan" \
            --title "INTERFACE NAME (opnlan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for opnlan" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (opnlan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU2=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for opnlan (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (opnlan)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

        BRIDGE3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "INTERFACE (3/3) DEFAULT: opnmgmt" 8 60 "opnmgmt" \
            --title "INTERFACE NAME (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MAC3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MAC Address for opnmgmt" 8 60 "$(generate_mac)" \
            --title "MAC ADDRESS (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
        MTU3=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "MTU Size for opnmgmt (Default: 1500)" 8 60 "1500" \
            --title "MTU SIZE (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "START VIRTUAL MACHINE" \
        --yesno "Start VM when completed?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        START_VM="yes"
    else
        START_VM="no"
    fi
}

function start_script() {
    if whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "SETTINGS" \
        --yesno "Use Default Settings?" --defaultno 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
        default_settings
    else
        advanced_settings
    fi
}

function prompt_root_password() {
    ROOT_PASSWORD=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ROOT PASSWORD" --passwordbox "Enter root password:" 10 60 --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script
    if [ -z "$ROOT_PASSWORD" ]; then
        msg_error "No password entered. Exiting..."
        exit 1
    fi
}

function prompt_network_configuration() {
    LAN_IPV4=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Enter LAN IPv4 Address:" 8 60 --title "LAN IPv4 ADDRESS" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$LAN_IPV4" ]; then
        msg_error "No LAN IPv4 Address entered. Exiting..."
        exit 1
    fi

    SUBNET_MASK=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --inputbox "Enter Subnet Mask (CIDR format, e.g., 24):" 8 60 --title "SUBNET MASK" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$SUBNET_MASK" ]; then
        msg_error "No Subnet Mask entered. Exiting..."
        exit 1
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "DHCP SERVER" --yesno "Enable DHCP Server?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        ENABLE_DHCP="yes"
        DHCP_START=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Start of DHCP range:" 8 60 --title "DHCP RANGE START" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        if [ -z "$DHCP_START" ]; then
            msg_error "No DHCP Start Range entered. Exiting..."
            exit 1
        fi

        DHCP_END=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "End of DHCP range:" 8 60 --title "DHCP RANGE END" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        if [ -z "$DHCP_END" ]; then
            msg_error "No DHCP End Range entered. Exiting..."
            exit 1
        fi
    else
        ENABLE_DHCP="no"
    fi

    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "HTTPS ACCESS" --yesno "Enable HTTPS for Web GUI?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        ENABLE_HTTPS="y"
    else
        ENABLE_HTTPS="n"
    fi
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

function convert_date() {
    local input_date="$1"
    local year month day
    year=$(echo "$input_date" | cut -d'-' -f1)
    month=$(echo "$input_date" | cut -d'-' -f2)
    day=$(echo "$input_date" | cut -d'-' -f3)
    case $month in
        Jan) month="01" ;;
        Feb) month="02" ;;
        Mar) month="03" ;;
        Apr) month="04" ;;
        May) month="05" ;;
        Jun) month="06" ;;
        Jul) month="07" ;;
        Aug) month="08" ;;
        Sep) month="09" ;;
        Oct) month="10" ;;
        Nov) month="11" ;;
        Dec) month="12" ;;
        *) echo "Invalid month"; exit 1 ;;
    esac
    formatted_date="${year}${month}${day}"
}

check_root
check_dependencies
arch_check
pve_check
ssh_check

TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null

if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "OPNsense VM" \
    --yesno "This will create a New OPNsense VM. Proceed?" 10 58 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
    header_info && echo -e "User exited script.\n" && exit 1
fi

if ! whiptail --backtitle "Proxmox VE OPNsense Install Script" \
    --title "MANAGE PROXMOX INTERFACES" \
    --yesno "Would you like the script to manage and configure the Proxmox host network interfaces and add them to the VM?\nIf no, the VM will not have the predefined interfaces set." 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"; then
    MANAGE_INTERFACES="no"
else
    MANAGE_INTERFACES="yes"
fi

start_script

msg_info "Validating Storage"
STORAGE_MENU=()
while read -r line; do
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')
    ITEM="Type: $TYPE Free: $FREE"
    STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')

if [ ${#STORAGE_MENU[@]} -eq 0 ]; then
    msg_error "Unable to detect a valid storage location."
    exit 1
fi

STORAGE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "Storage Pools" --radiolist \
    "Which storage pool you would like to use for ${HN}?\nUse Spacebar to select." \
16 80 6 "${STORAGE_MENU[@]}" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

if [ -z "${STORAGE}" ]; then
    STORAGE="${STORAGE_MENU[0]}"
fi
msg_ok "Using $STORAGE for Storage Location."
msg_ok "Virtual Machine ID is $VMID."

msg_info "Getting newest OPNsense version from the mirror..."
MIRROR_URL="https://mirrors.ocf.berkeley.edu/opnsense/releases/mirror/"
NEWEST_ISO=$(curl -s "$MIRROR_URL" | grep -oP 'OPNsense-\d+\.\d+-dvd-amd64\.iso\.bz2' | sort -V | tail -n1 || true)

if [[ -n "$NEWEST_ISO" ]]; then
    release_date=$(curl -s "$MIRROR_URL" | grep "$NEWEST_ISO" | grep -oP '[0-9]{4}-[A-Z][a-z]{2}-[0-9]{2}' | head -1 || true)
fi

if [[ -n "$NEWEST_ISO" && -n "$release_date" ]]; then
    msg_ok "Detected newest ISO: $NEWEST_ISO"
    convert_date "$release_date"
    echo "Formatted release date: $formatted_date"
    URL="${MIRROR_URL}${NEWEST_ISO}"
    BZ2_FILE="${formatted_date}-${NEWEST_ISO}"
    ISO_FILE="${BZ2_FILE%.bz2}"
    BZ2_PATH="/var/lib/vz/template/iso/$BZ2_FILE"
    ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
else
    msg_error "Could not determine newest version from mirror. Falling back..."
    URL="$FALLBACK_URL"
    release_date="$FALLBACK_RELEASE_DATE"
    convert_date "$release_date"
    ISO_FILE="${formatted_date}-OPNsense-24.7-dvd-amd64.iso"
    BZ2_FILE="${ISO_FILE}.bz2"
    BZ2_PATH="/var/lib/vz/template/iso/$BZ2_FILE"
    ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
fi

if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
    --title "ISO SELECTION" \
    --yesno "Would you like to download the OPNsense ISO from the internet?\n\nChoose 'No' to select a locally available ISO." 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
    if [ -f "$ISO_PATH" ]; then
        msg_ok "ISO file already exists: $ISO_FILE"
    else
        msg_info "Downloading from $URL"
        if ! wget -q --show-progress "$URL" -O "$BZ2_PATH"; then
            msg_error "Failed to download from $URL."
            if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "LOCAL ISO" \
                --yesno "Download failed. Select a locally available ISO?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
                ISO_LIST=()
                while IFS= read -r iso_file; do
                    ISO_LIST+=("$(basename "$iso_file")" "")
                done < <(find /var/lib/vz/template/iso -type f -name "*.iso")

                if [ ${#ISO_LIST[@]} -eq 0 ]; then
                    msg_error "No .iso files found in /var/lib/vz/template/iso."
                    exit 1
                fi

                ISO_FILE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
                    --title "Local ISO Files" \
                    --radiolist "Select a local ISO file:" 16 60 6 \
                    "${ISO_LIST[@]}" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

                if [ -z "${ISO_FILE}" ]; then
                    msg_error "No ISO selected. Exiting..."
                    exit 1
                fi
                ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
            else
                msg_error "Exiting due to inability to retrieve ISO."
                exit 1
            fi
        else
            echo -en "\e[1A\e[0K"
            msg_ok "Downloaded $BZ2_FILE"
            if ! bunzip2 "$BZ2_PATH"; then
                msg_error "Failed to extract $BZ2_FILE."
                exit 1
            fi
            msg_ok "Extracted $BZ2_FILE to $ISO_FILE"
        fi
    fi
else
    ISO_LIST=()
    while IFS= read -r iso_file; do
        ISO_LIST+=("$(basename "$iso_file")" "")
    done < <(find /var/lib/vz/template/iso -type f -name "*.iso")

    if [ ${#ISO_LIST[@]} -eq 0 ]; then
        msg_error "No .iso files found in /var/lib/vz/template/iso."
        exit 1
    fi

    ISO_FILE=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "Local ISO Files" \
        --radiolist "Select a local ISO file:" 16 60 6 \
        "${ISO_LIST[@]}" --cancel-button "Exit Script" 3>&1 1>&2 2<&3) || exit_script

    if [ -z "${ISO_FILE}" ]; then
        msg_error "No ISO selected. Exiting..."
        exit 1
    fi
    ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
    msg_ok "Using local ISO: $ISO_FILE"
fi

STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
    nfs|dir|btrfs)
        DISK_EXT=".qcow2"
        DISK_REF="$VMID/"
        DISK_IMPORT="-format qcow2"
    ;;
esac

msg_info "Creating an OPNsense VM"
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    NET_OPTS="-net0 virtio,bridge=$BRIDGE1,macaddr=$MAC1,mtu=$MTU1 -net1 virtio,bridge=$BRIDGE2,macaddr=$MAC2,mtu=$MTU2 -net9 virtio,bridge=$BRIDGE3,macaddr=$MAC3,mtu=$MTU3"
else
    NET_OPTS=""
fi

qm create "$VMID" -agent enabled=1 -tablet 0 -localtime 1 -bios ovmf -machine "$MACHINE" -cpu "$CPU_TYPE" -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
-name "$HN" -tags firewall $NET_OPTS -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

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
    if qm set "$VMID" -scsi0 "${STORAGE}:${DISK0}"; then
        msg_ok "Main disk attached successfully"
        break
    else
        msg_error "Attempt $i: Failed to attach main disk. Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    fi
    if [ $i -eq $RETRY_COUNT ]; then
        msg_error "Exceeded maximum retry attempts to attach main disk. Exiting."
        exit 1
    fi
done

qm set "$VMID" -ide2 "local:iso/$ISO_FILE,media=cdrom"
msg_info "Setting boot order"
qm set "$VMID" -boot order=ide2;order=scsi0

CREATION_DATE=$(date +"%Y-%m-%d")
ISO_USED="$ISO_FILE"
qm set "$VMID" \
-description "# OPNsense - VM - $VMID - Created $CREATION_DATE - ISO Used: $ISO_USED</div><div align='center'><a href='https://opnsense.org/' target='_blank' rel='noopener noreferrer'><img src='https://icons.iconarchive.com/icons/simpleicons-team/simple/512/opnsense-icon.png'/></a><br><br>"

msg_ok "Created an OPNsense VM (${HN})"

if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "START VIRTUAL MACHINE" \
    --yesno "Would you like to start the VM now?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "AUTOMATE SETUP" \
        --yesno "Would you like to automate the setup?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        prompt_root_password
        prompt_network_configuration
        msg_info "Starting OPNsense VM"
        qm start "$VMID"
        msg_info "VM Started. Proceeding to automate the installation."
        automate_install
    else
        msg_info "Starting OPNsense VM"
        qm start "$VMID"
        whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "INSTALL OPNsense" \
            --msgbox "Install OPNsense to the VM now. When complete, press Enter." 10 60 --ok-button "Ok"
        if (whiptail --backtitle "Proxmox VE OPNsense Install Script" --title "REMOVE CD DRIVE" \
            --yesno "Remove Mounted CD drive device from VM and set boot to VM drive?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
            qm stop "$VMID"
            msg_info "Removing CD drive and setting boot to VM drive"
            qm set "$VMID" -delete ide2
            qm set "$VMID" -boot order=scsi0
            qm start "$VMID"
            msg_ok "Removed CD drive and set boot to VM drive"
        else
            msg_info "CD drive not removed. Boot order unchanged."
        fi
    fi
else
    msg_info "VM creation complete. VM not started."
fi

# Only ask to add interfaces if we managed interfaces
if [ "$MANAGE_INTERFACES" = "yes" ]; then
    if (whiptail --backtitle "Proxmox VE OPNsense Install Script" \
        --title "ADD INTERFACES" --yesno "Would you like to add the interfaces to /etc/network/interfaces?" 10 60 --yes-button "Yes" --no-button "No" --cancel-button "Exit Script"); then
        msg_info "Listing physical interfaces"
        PHYSICAL_INTERFACES=$(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}')
        echo "Available physical interfaces:"
        echo "$PHYSICAL_INTERFACES"

        BRIDGE_PORT_WAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE1 (opnwan)" 8 60 --title "BRIDGE-PORTS (opnwan)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        BRIDGE_PORT_LAN=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE2 (opnlan)" 8 60 --title "BRIDGE-PORTS (opnlan)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        BRIDGE_PORT_MGMT=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter bridge-ports for $BRIDGE3 (opnmgmt)" 8 60 --title "BRIDGE-PORTS (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

        MGMT_IP=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter static IP address for $BRIDGE3 (opnmgmt)" 8 60 --title "MGMT IP (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script
        MGMT_GW=$(whiptail --backtitle "Proxmox VE OPNsense Install Script" \
            --inputbox "Enter gateway for $BRIDGE3 (opnmgmt)" 8 60 --title "MGMT GATEWAY (opnmgmt)" --cancel-button "Exit Script" 3>&1 1>&2 2>&3) || exit_script

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
        bridge-fd 0" | sudo tee -a /etc/network/interfaces > /dev/null

        msg_ok "Interfaces added to /etc/network/interfaces"
    fi
fi

msg_ok "Completed Successfully!"
