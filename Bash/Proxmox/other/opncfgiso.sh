#!/usr/bin/env bash
# Purpose: Create an OPNsense configuration ISO and attach it to a Proxmox VM
# Usage: bash opncfgiso.sh -vmid 100 -cfgxml /path/to/opnconfig.xml [-storage storage_name] [-help]

set -euo pipefail

#################################################################################
# Configuration Settings                                                         #
#################################################################################

# Default ISO storage location (will use 'local' if not specified)
DEFAULT_STORAGE="local"

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
CONFIG_XML_PATH=""
ISO_STORAGE=""

function error_handler() {
    local exit_code=$?
    local line_number="$1"
    local command="$2"
    echo -e "\n${RD}[ERROR]${CL} Line $line_number: exit code $exit_code while executing: $command\n"
    cleanup
    exit $exit_code
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
    local deps=(qm pvesh pvesm genisoimage xmlstarlet)

    # Map each command to its corresponding Debian package
    declare -A cmd_pkg_map=(
        [qm]=qemu-utils
        [pvesh]=pve-manager
        [pvesm]=pve-manager
        [genisoimage]=genisoimage
        [xmlstarlet]=xmlstarlet
    )

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
        msg_info "All required dependencies are already installed."
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
                        msg_info "Updating package lists..."
                        if ! apt-get update; then
                            msg_error "Failed to update package lists. Please check your network connection."
                            exit 1
                        fi
                        updated=true
                    fi

                    # Install the package
                    msg_info "Installing package '$pkg'..."
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

    msg_ok "All dependencies have been handled."
}

function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        msg_error "Please run this script as root."
        echo -e "\nExiting..."
        sleep 2
        exit 1
    fi
}

function pve_check() {
    if ! pveversion &>/dev/null; then
        msg_error "This script must be run on a Proxmox VE system."
        echo -e "Exiting..."
        sleep 2
        exit 1
    fi
}

function check_vm_exists() {
    if ! qm status "$VMID" &>/dev/null; then
        msg_error "VM ID $VMID does not exist. Please specify a valid VM ID."
        exit 1
    fi
}

#################################################################################
# Config ISO Creation Functions                                                  #
#################################################################################

function usage() {
    cat << EOF
Usage: $0 options

This script creates an ISO with OPNsense configuration and attaches it to a Proxmox VM.

OPTIONS:
   -h, --help                Show this message
   -vmid, --vm-id            Proxmox VM ID to attach the ISO to (required)
   -cfgxml, --config-xml     Path to the OPNsense config.xml file (required)
   -storage, --storage       Proxmox storage location for the ISO (default: local)

Example:
   $0 -vmid 100 -cfgxml /path/to/opnconfig.xml
   $0 -vmid 100 -cfgxml /path/to/opnconfig.xml -storage local-lvm

EOF
    exit 1
}

function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -vmid|--vm-id)
                VMID="$2"
                shift 2
                ;;
            -cfgxml|--config-xml)
                CONFIG_XML_PATH="$2"
                shift 2
                ;;
            -storage|--storage)
                ISO_STORAGE="$2"
                shift 2
                ;;
            *)
                msg_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$VMID" ]]; then
        msg_error "VM ID is required. Use -vmid or --vm-id to specify."
        usage
    fi

    if [[ -z "$CONFIG_XML_PATH" ]]; then
        msg_error "Config.xml path is required. Use -cfgxml or --config-xml to specify."
        usage
    fi

    # Set default storage if not specified
    if [[ -z "$ISO_STORAGE" ]]; then
        ISO_STORAGE="$DEFAULT_STORAGE"
    fi
}

function validate_inputs() {
    # Check if config.xml exists
    if [[ ! -f "$CONFIG_XML_PATH" ]]; then
        msg_error "Config file not found: $CONFIG_XML_PATH"
        exit 1
    fi

    # Check if VM exists
    check_vm_exists

    # Check if storage exists
    if ! pvesm status | grep -q "^$ISO_STORAGE"; then
        msg_error "Storage '$ISO_STORAGE' does not exist. Available storages:"
        pvesm status | grep -v "^Name" | awk '{print "  - " $1}'
        exit 1
    fi

    # Check if storage is allowed to store ISO files
    if ! pvesm status -content iso | grep -q "^$ISO_STORAGE"; then
        msg_error "Storage '$ISO_STORAGE' cannot store ISO files. Choose from:"
        pvesm status -content iso | grep -v "^Name" | awk '{print "  - " $1}'
        exit 1
    fi
}

function create_and_attach_iso() {
    local CONFIG_LABEL="CONFIG"
    local iso_name="opnconfig-${VMID}.iso"
    TEMP_DIR=$(mktemp -d)
    
    msg_info "Creating temporary work directory..."
    
    # Create the directory structure
    mkdir -p "${TEMP_DIR}/conf"
    
    # Copy the config file
    msg_info "Copying config.xml to temporary location..."
    if ! cp "${CONFIG_XML_PATH}" "${TEMP_DIR}/conf/config.xml"; then
        msg_error "Failed to copy config file"
        exit 1
    fi

    # Blank out all user passwords for security
    msg_info "Processing user passwords in configuration..."

    # Blank all password fields (if xmlstarlet is available)
    if command -v xmlstarlet &>/dev/null; then
        if ! xmlstarlet ed -L \
            -u "//user/password" -v "" \
            "${TEMP_DIR}/conf/config.xml"; then
            msg_error "Failed to blank user passwords in configuration"
            exit 1
        fi
        msg_ok "Password fields blanked for security."
    else
        msg_info "xmlstarlet not found - skipping password blanking"
    fi

    # Verify the file was copied correctly
    if ! [ -f "${TEMP_DIR}/conf/config.xml" ]; then
        msg_error "Config file not found in expected location after copy"
        exit 1
    fi

    # Create the ISO
    msg_info "Creating configuration ISO..."
    if ! genisoimage -quiet -o "${TEMP_DIR}/${iso_name}" -V "${CONFIG_LABEL}" -r -J "${TEMP_DIR}"; then
        msg_error "Failed to create config image"
        exit 1
    fi

    # Verify ISO was created
    if ! [ -f "${TEMP_DIR}/${iso_name}" ]; then
        msg_error "ISO file not found after creation"
        exit 1
    fi

    # Move ISO to storage
    local iso_storage_path
    if [ "$ISO_STORAGE" = "local" ]; then
        iso_storage_path="/var/lib/vz/template/iso"
    else
        iso_storage_path="$(pvesm path "$ISO_STORAGE")/template/iso"
    fi
    
    msg_info "Moving ISO to storage location..."
    mkdir -p "$iso_storage_path"
    
    if ! mv "${TEMP_DIR}/${iso_name}" "${iso_storage_path}/${iso_name}"; then
        msg_error "Failed to move config image to storage"
        exit 1
    fi

    # Verify ISO exists in final location
    if ! [ -f "${iso_storage_path}/${iso_name}" ]; then
        msg_error "ISO file not found in final location"
        exit 1
    fi

    # Check if VM already has an ISO attached to ide2
    if qm config "$VMID" | grep -q "ide2:"; then
        msg_info "VM already has a drive attached to ide2"
        if ! qm set "$VMID" --delete ide2; then
            msg_error "Failed to remove existing drive from ide2"
            exit 1
        fi
        msg_ok "Removed existing drive from ide2"
    fi

    # Attach the ISO to the VM as ide2
    msg_info "Attaching configuration ISO to VM..."
    if ! qm set "${VMID}" --ide2 "${ISO_STORAGE}:iso/${iso_name},media=cdrom"; then
        msg_error "Failed to attach config image to VM"
        rm -f "${iso_storage_path}/${iso_name}"
        exit 1
    fi

    msg_ok "Config image created and attached as ide2 to VM $VMID"
    echo "------------------------------------------------------------"
    echo "To import the configuration in OPNsense:"
    echo "1. Boot the VM"
    echo "2. Login as root"
    echo "3. Select option 8 (Shell)"
    echo "4. Run: opnsense-importer"
    echo "5. Select cd0 as the configuration source"
    echo "------------------------------------------------------------"
}

#################################################################################
# Main Script Execution
#################################################################################

# Print header
echo "--------------------------------------------------------------"
echo "  OPNsense Configuration ISO Generator for Proxmox"
echo "--------------------------------------------------------------"

# Check environment
check_root
pve_check
check_dependencies

# Parse arguments
parse_args "$@"

# Validate inputs
validate_inputs

# Create and attach the ISO
create_and_attach_iso

msg_ok "Operation completed successfully!"
exit 0
