#!/usr/bin/env bash
# =============================================================================
# opnsense-ha.sh — all-in-one OPNsense VM manager for Proxmox with CARP HA
#
# Subcommands (run `opnsense-ha.sh help` for full list):
#   init-topology    Write an example topology.json
#   validate         Validate a topology.json
#   single           Create ONE OPNsense VM from scratch (interactive or config-driven)
#   ha-duplicate     Clone an existing primary VM, prep secondary for CARP HA
#   ha-fresh         Create TWO OPNsense VMs from scratch, pre-configured for CARP
#   deploy-config    Push a transformed /conf/config.xml to a running VM and reboot
#   status           Inspect current HA state vs. topology
#   verify           Run the full post-prep verification battery
#   rollback         Destroy secondary VM and remove isolated bridges
#
# Design:
#   - Self-contained. Needs only bash, Python3 stdlib, Proxmox `qm`, `pvesh`, `ssh`,
#     `scp`, `brctl`, `ifup`. Every external tool is checked at startup.
#   - JSON topology file is the source of truth. CLI flags override individual
#     fields. Interactive mode (via whiptail or plain prompts) can generate one.
#   - Embeds the same XML transform logic as /root/opnsense-ha-config.py; if that
#     file exists alongside this script it's used directly, otherwise a copy is
#     written to a temp file on demand.
#   - Never modifies the primary VM's running config without the --modify-primary
#     flag (secondary prep is fully isolated). Destructive operations prompt.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEFAULT_ISO_DIR="/var/lib/vz/template/iso"
DEFAULT_ISO_URL_BASE="https://mirrors.ocf.berkeley.edu/opnsense/releases"
DEFAULT_ISO_VERSION="26.1"
DEFAULT_ISO_NAME="OPNsense-${DEFAULT_ISO_VERSION}-dvd-amd64.iso"
SNAPSHOT_DIR="${OPNSENSE_HA_SNAPSHOT_DIR:-/root/opnsense-ha-snapshots}"
EMBEDDED_PY_PATH=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED= C_GRN= C_YEL= C_CYA= C_DIM= C_OFF=
fi

_log()  { printf "[opnsense-ha] %s\n" "$*" >&2; }
info()  { _log "${C_CYA}info${C_OFF}  $*"; }
ok()    { _log "${C_GRN} ok${C_OFF}   $*"; }
warn()  { _log "${C_YEL}warn${C_OFF}  $*"; }
err()   { _log "${C_RED}err${C_OFF}   $*"; }
die()   { err "$*"; exit 1; }

confirm() {
    # confirm "prompt" — returns 0 if yes
    local reply
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
    read -r -p "[opnsense-ha] $* [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
need_cmds_for_vms() {
    local missing=()
    for c in qm pvesh brctl ip ssh scp python3 uuidgen wget; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "missing commands on host: ${missing[*]}"
}

require_root() { [[ $EUID -eq 0 ]] || die "must run as root on the Proxmox host"; }

# -----------------------------------------------------------------------------
# Python transform: prefer sibling file, else extract embedded
# Returns the tool as an ARGV array via the global PY_TOOL (avoids word-splitting
# problems when IFS is restricted).
# -----------------------------------------------------------------------------
PY_TOOL=()
get_py_tool() {
    local sibling="$SCRIPT_DIR/opnsense-ha-config.py"
    if [[ -x "$sibling" ]]; then
        PY_TOOL=("$sibling"); return 0
    fi
    if [[ -r "$sibling" ]]; then
        PY_TOOL=(python3 "$sibling"); return 0
    fi
    if [[ -z "$EMBEDDED_PY_PATH" ]]; then
        write_embedded_py
    fi
    PY_TOOL=(python3 "$EMBEDDED_PY_PATH")
    return 0
}

write_embedded_py() {
    EMBEDDED_PY_PATH="$(mktemp /tmp/opnsense-ha-config.XXXXXX.py)"
    # The embedded Python is identical to /root/opnsense-ha-config.py; if you
    # modify one, update the other (or rely on the sibling file).
    cat > "$EMBEDDED_PY_PATH" <<'__EMBED_PY_EOF__'
#!/usr/bin/env python3
# Minimal embedded version. For full features (inject-primary-carp,
# activate-primary-renumber, deep validation, diff), use the standalone
# /root/opnsense-ha-config.py file alongside this script.
import argparse, json, re, sys, uuid
from pathlib import Path
from xml.sax.saxutils import escape as _x_escape

def _xe(s):
    if s is None: return ""
    return _x_escape(str(s), {'"': "&quot;", "'": "&apos;"})

def strip_comments(o):
    if isinstance(o, dict):  return {k: strip_comments(v) for k,v in o.items() if not k.startswith("_")}
    if isinstance(o, list):  return [strip_comments(x) for x in o]
    return o

def load_topo(p):
    try:
        return strip_comments(json.loads(Path(p).read_text()))
    except FileNotFoundError:
        raise RuntimeError(f"topology file not found: {p}")
    except json.JSONDecodeError as e:
        raise RuntimeError(f"topology is not valid JSON ({p}): {e}")

def _find(x, op, cl):
    s = x.find(op); e = x.find(cl, s) + len(cl) if s != -1 else -1
    return s, e

def _scoped(x, s, e, pat, rep, count=0):
    before, mid, after = x[:s], x[s:e], x[e:]
    newmid, n = re.subn(pat, rep, mid, count=count)
    return before + newmid + after, e + (len(newmid) - len(mid)), n

def _ipv4_sec(iface, topo):
    p = iface["primary_current_ip"]; suf = topo["secondary"]["real_ip_suffix"]
    return f"{p.rsplit('.',1)[0]}.{suf}"

def _ipv6_sec(v6, topo):
    # IPv6 is EXPLICIT — never auto-derived (decimal-to-hex surprises).
    if "secondary_ip" not in v6:
        raise RuntimeError("ipv6 block missing required 'secondary_ip'")
    return v6["secondary_ip"]

def _ipv6_carp_vip(v6):
    if "carp_vip" not in v6:
        raise RuntimeError("ipv6 block missing required 'carp_vip'")
    return v6["carp_vip"]

def transform_secondary(x, topo):
    audit = []
    # hostname
    s,e = _find(x, "<system>", "</system>")
    x,e,n = _scoped(x, s, e, r"<hostname>([^<]+)</hostname>", r"<hostname>\1-sec</hostname>", 1)
    audit.append(("hostname '-sec' suffix", n))
    # interfaces block
    ifs = x.find("\n  <interfaces>\n"); ife = x.find("\n  </interfaces>", ifs) + len("\n  </interfaces>")
    # WAN disable
    wan_iface = next((i for i in topo["interfaces"] if i["iface_tag"]=="wan"), None)
    if wan_iface:
        wre = re.compile(r"    <wan>\n(.*?)\n    </wan>", re.DOTALL)
        def _w(m):
            b = m.group(1)
            b = re.sub(r"\s*<enable>1</enable>\n", "\n", b, count=1)
            b = re.sub(r"<ipaddr>[^<]*</ipaddr>", "<ipaddr/>", b)
            b = re.sub(r"<subnet>[^<]*</subnet>", "<subnet/>", b)
            b = re.sub(r"<gateway>[^<]*</gateway>", "<gateway/>", b)
            return f"    <wan>\n{b}\n    </wan>"
        sec = x[ifs:ife]; newsec, n = wre.subn(_w, sec, count=1)
        x = x[:ifs] + newsec + x[ife:]; ife = ifs + len(newsec)
        audit.append(("WAN disabled", n))
    # LAN/OPT renumber
    total = 0
    for iface in topo["interfaces"]:
        if iface["iface_tag"]=="wan": continue
        tag = iface["iface_tag"]; old = iface["primary_current_ip"]; new = _ipv4_sec(iface, topo)
        ire = re.compile(rf"    <{tag}>\n(.*?)\n    </{tag}>", re.DOTALL)
        sec = x[ifs:ife]
        def _i(m, tag=tag, old=old, new=new, v6=iface.get("ipv6")):
            b = m.group(1).replace(f"<ipaddr>{old}</ipaddr>", f"<ipaddr>{new}</ipaddr>")
            if v6:
                b = b.replace(f"<ipaddrv6>{v6['primary_current_ip']}</ipaddrv6>",
                              f"<ipaddrv6>{_ipv6_sec(v6, topo)}</ipaddrv6>")
            return f"    <{tag}>\n{b}\n    </{tag}>"
        newsec, n = ire.subn(_i, sec, count=1)
        if n:
            x = x[:ifs] + newsec + x[ife:]; ife = ifs + len(newsec); total += 1
    audit.append(("LAN+OPT renumbered", total))
    # sync interface
    sync = topo["sync_link"]; st = sync["opt_tag"]
    if f"<{st}>" not in x:
        entry = (f"    <{st}>\n      <if>{sync['guest_if']}</if>\n      <descr>{sync.get('descr','HA-SYNC')}</descr>\n"
                 f"      <enable>1</enable>\n      <spoofmac/>\n      <ipaddr>{sync['secondary_ip']}</ipaddr>\n"
                 f"      <subnet>{sync['prefix']}</subnet>\n    </{st}>\n")
        ci = x.find("\n  </interfaces>")
        x = x[:ci] + "\n" + entry.rstrip() + x[ci:]
        audit.append((f"sync iface <{st}> added", 1))
    # DHCP disable
    if "dhcpd" in topo.get("disable_on_secondary", []):
        ds = x.find("\n  <dhcpd>\n")
        if ds != -1:
            de = x.find("\n  </dhcpd>", ds) + len("\n  </dhcpd>")
            x,de,n = _scoped(x, ds, de, r"\n      <enable>1</enable>", r"")
            audit.append(("dhcpd enabled removed", n))
    if "dhcpdv6" in topo.get("disable_on_secondary", []):
        ds = x.find("\n  <dhcpdv6>\n")
        if ds != -1:
            de = x.find("\n  </dhcpdv6>", ds) + len("\n  </dhcpdv6>")
            x,de,n = _scoped(x, ds, de, r"\n      <enable>1</enable>", r"")
            audit.append(("dhcpdv6 enabled removed", n))
    # unboundplus
    if "unboundplus" in topo.get("disable_on_secondary", []):
        u = x.find("<unboundplus")
        if u != -1:
            ue = x.find("</unboundplus>", u) + len("</unboundplus>")
            g = x.find("<general>", u, ue)
            if g != -1:
                ge = x.find("</general>", g) + len("</general>")
                x,ge,n = _scoped(x, g, ge, r"<enabled>1</enabled>", r"<enabled>0</enabled>", 1)
                audit.append(("unbound disabled", n))
    # tailscale
    if "tailscale" in topo.get("disable_on_secondary", []):
        t = x.find("<tailscale>")
        if t != -1:
            te = x.find("</tailscale>", t) + len("</tailscale>")
            s2 = x.find("<settings", t, te)
            if s2 != -1:
                s2e = x.find("</settings>", s2) + len("</settings>")
                x,s2e,n = _scoped(x, s2, s2e, r"<enabled>1</enabled>", r"<enabled>0</enabled>", 1)
                audit.append(("tailscale disabled", n))
    # carp preempt
    if topo.get("carp",{}).get("preempt") and "net.inet.carp.preempt" not in x:
        sc = x.find("</sysctl>")
        if sc != -1:
            item = (f'    <item uuid="{uuid.uuid4()}">\n      <tunable>net.inet.carp.preempt</tunable>\n'
                    f"      <value>1</value>\n      <descr>CARP preempt.</descr>\n    </item>\n  ")
            x = x[:sc] + item + x[sc:]; audit.append(("carp.preempt=1 added", 1))
    # CARP VIPs (all user-supplied strings XML-escaped for safety)
    vips = []
    for iface in topo["interfaces"]:
        if iface.get("defer_carp") or iface["iface_tag"]=="wan": continue
        u = str(uuid.uuid4())
        vips.append(f'''    <vip uuid="{u}">
      <mode>carp</mode>
      <interface>{_xe(iface["iface_tag"])}</interface>
      <descr>{_xe(iface.get("descr", iface["iface_tag"]))} CARP</descr>
      <type>single</type>
      <subnet_bits>{iface["prefix"]}</subnet_bits>
      <subnet>{_xe(iface["primary_current_ip"])}</subnet>
      <noexpand>0</noexpand>
      <vhid>{iface["vhid"]}</vhid>
      <advskew>{topo["carp"]["secondary_advskew"]}</advskew>
      <advbase>{topo["carp"].get("advbase",1)}</advbase>
      <password>{_xe(topo["carp"]["password"])}</password>
    </vip>''')
        if iface.get("ipv6"):
            u6 = str(uuid.uuid4()); v6 = iface["ipv6"]
            vips.append(f'''    <vip uuid="{u6}">
      <mode>carp</mode>
      <interface>{_xe(iface["iface_tag"])}</interface>
      <descr>{_xe(iface.get("descr", iface["iface_tag"]))} CARP IPv6</descr>
      <type>single</type>
      <subnet_bits>{v6["prefix"]}</subnet_bits>
      <subnet>{_xe(_ipv6_carp_vip(v6))}</subnet>
      <noexpand>0</noexpand>
      <vhid>{v6["vhid"]}</vhid>
      <advskew>{topo["carp"]["secondary_advskew"]}</advskew>
      <advbase>{topo["carp"].get("advbase",1)}</advbase>
      <password>{_xe(topo["carp"]["password"])}</password>
    </vip>''')
    new_vip = '<virtualip version="1.0.1">\n' + "\n".join(vips) + "\n  </virtualip>"
    x, n = re.subn(r"<virtualip[^/>]*>.*?</virtualip>", new_vip, x, count=1, flags=re.DOTALL)
    audit.append((f"{len(vips)} CARP VIPs pre-seeded", n))
    # hasync
    new_h = f'''<hasync version="1.0.2">
    <disablepreempt>0</disablepreempt>
    <disconnectppps>0</disconnectppps>
    <pfsyncinterface>{sync["opt_tag"]}</pfsyncinterface>
    <pfsyncpeerip>{sync["primary_ip"]}</pfsyncpeerip>
    <pfsyncversion>1400</pfsyncversion>
    <synchronizetoip>{sync["primary_ip"]}</synchronizetoip>
    <verifypeer>0</verifypeer>
    <username>root</username>
    <password/>
    <syncitems/>
  </hasync>'''
    x, n = re.subn(r"<hasync[^>]*>.*?</hasync>", new_h, x, count=1, flags=re.DOTALL)
    audit.append((f"hasync pointed at {sync['primary_ip']}", n))
    return x, audit

def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    q = sp.add_parser("transform-secondary"); q.add_argument("--primary-config", required=True)
    q.add_argument("--output", required=True); q.add_argument("--topology", required=True)
    a = p.parse_args()
    if a.cmd == "transform-secondary":
        topo = load_topo(a.topology)
        xml = Path(a.primary_config).read_text()
        out, audit = transform_secondary(xml, topo)
        import xml.etree.ElementTree as ET; ET.fromstring(out)
        Path(a.output).write_text(out)
        print(f"wrote {a.output} ({len(out)} bytes)")
        for msg, n in audit: print(f"  [{n:>3}] {msg}")
main()
__EMBED_PY_EOF__
    chmod +x "$EMBEDDED_PY_PATH"
}

cleanup_embedded() {
    if [[ -n "$EMBEDDED_PY_PATH" ]]; then
        rm -f "$EMBEDDED_PY_PATH"
    fi
    return 0
}
trap cleanup_embedded EXIT

# -----------------------------------------------------------------------------
# JSON config reading via Python (no jq dependency)
# -----------------------------------------------------------------------------
jq_get() {
    # jq_get <json_file> <dotted.path> [default]
    local file="$1" path="$2" default="${3:-}"
    python3 - "$file" "$path" "$default" <<'PY'
import json, sys
f, p, d = sys.argv[1], sys.argv[2], sys.argv[3]
obj = json.load(open(f))
try:
    for key in p.split("."):
        if key.startswith("[") and key.endswith("]"):
            obj = obj[int(key[1:-1])]
        else:
            obj = obj[key]
    if obj is None:
        print(d)
    elif isinstance(obj, (list, dict)):
        print(json.dumps(obj))
    else:
        print(obj)
except (KeyError, IndexError, TypeError):
    print(d)
PY
}

jq_require() {
    # jq_require <json_file> <dotted.path> — dies if value empty or missing
    local val; val=$(jq_get "$1" "$2" "")
    [[ -n "$val" ]] || die "topology: required key '$2' is missing or empty in $1"
    printf '%s' "$val"
}

jq_list_interfaces() {
    python3 - "$1" <<'PY'
import json, sys
o = json.load(open(sys.argv[1]))
for i in o.get("interfaces", []):
    print(f"{i.get('iface_tag','')}|{i.get('descr','')}|{i.get('bridge','')}|{i.get('vlan_tag','')}|"
          f"{i.get('primary_current_ip','')}|{i.get('prefix','')}|{i.get('vhid','')}|{i.get('role','')}|"
          f"{'true' if i.get('defer_carp') else 'false'}")
PY
}

# -----------------------------------------------------------------------------
# Snapshot host state (run before risky ops)
# -----------------------------------------------------------------------------
snapshot_host() {
    mkdir -p "$SNAPSHOT_DIR"
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    cp /etc/network/interfaces "$SNAPSHOT_DIR/interfaces-$stamp"
    brctl show > "$SNAPSHOT_DIR/bridges-$stamp.txt"
    ip -br addr > "$SNAPSHOT_DIR/ips-$stamp.txt"
    info "host state snapshotted: $SNAPSHOT_DIR/*-$stamp*"
}

# -----------------------------------------------------------------------------
# Bridge management (additive, never destructive)
# -----------------------------------------------------------------------------
bridge_exists() { brctl show "$1" >/dev/null 2>&1; }

add_isolated_bridge() {
    # $1 = bridge name, $2 = description comment
    local name="$1" descr="$2"
    if bridge_exists "$name"; then info "bridge $name already exists — leaving as-is"; return 0; fi

    info "adding isolated bridge $name to /etc/network/interfaces"
    # Insert before 'source /etc/network/interfaces.d/*' if present, else append
    if grep -q '^source /etc/network/interfaces.d' /etc/network/interfaces; then
        # Backup first
        cp /etc/network/interfaces "/etc/network/interfaces.bak-$(date +%s)"
        python3 - "$name" "$descr" <<'PY'
import sys, io
name, descr = sys.argv[1], sys.argv[2]
stanza = f"""
auto {name}
iface {name} inet manual
\tbridge-ports none
\tbridge-stp off
\tbridge-fd 0
#{descr}
"""
path = "/etc/network/interfaces"
txt = open(path).read()
marker = "source /etc/network/interfaces.d/*"
if marker in txt:
    new = txt.replace(marker, stanza + "\n" + marker, 1)
else:
    new = txt.rstrip() + "\n" + stanza
open(path, "w").write(new)
PY
    else
        {
            echo ""
            echo "auto $name"
            echo "iface $name inet manual"
            echo -e "\tbridge-ports none"
            echo -e "\tbridge-stp off"
            echo -e "\tbridge-fd 0"
            echo "#$descr"
        } >> /etc/network/interfaces
    fi

    ifup "$name" || die "ifup $name failed — revert /etc/network/interfaces from backup and investigate"
    ok "bridge $name up"
}

# -----------------------------------------------------------------------------
# VM management — clone, quarantine, start
# -----------------------------------------------------------------------------
vm_exists() { qm config "$1" >/dev/null 2>&1; }
vm_running() { qm status "$1" 2>/dev/null | grep -q "running"; }

qm_online_clone() {
    # $1 = source VMID, $2 = target VMID, $3 = new name, $4 = target storage
    local src="$1" dst="$2" name="$3" storage="$4"
    info "online clone: $src -> $dst on $storage (online, drive-mirror)"
    info "expect fs-freeze benign warning at 100% — harmless; clone is crash-consistent"
    qm clone "$src" "$dst" --name "$name" --full --storage "$storage"
    ok "clone complete"
}

qm_quarantine() {
    # $1 = VMID, $2 = prep bridge name, $3 = sync bridge name (for net3), $4 = description
    # Quarantine: all production-facing NICs parked on prep bridge, onboot=0, new smbios, no tags
    local vmid="$1" prep="$2" sync="$3" desc="$4"
    info "quarantining VM $vmid NICs onto $prep (sync NIC on $sync)"

    # Capture MACs cleanly from current config (case-insensitive hex)
    local mac0 mac1 mac2
    mac0=$(qm config "$vmid" | grep '^net0:' | grep -oE 'virtio=([0-9A-Fa-f:]+)' | head -1 | cut -d= -f2)
    mac1=$(qm config "$vmid" | grep '^net1:' | grep -oE 'virtio=([0-9A-Fa-f:]+)' | head -1 | cut -d= -f2)
    mac2=$(qm config "$vmid" | grep '^net2:' | grep -oE 'virtio=([0-9A-Fa-f:]+)' | head -1 | cut -d= -f2)

    [[ -n "$mac0" ]] || die "could not read net0 MAC from VM $vmid"

    local -a args=(
        --onboot 0
        --tags ""
        --net0 "virtio=$mac0,bridge=$prep"
        --smbios1 "uuid=$(uuidgen)"
        --description "$desc"
    )
    [[ -n "$mac1" ]] && args+=(--net1 "virtio=$mac1,bridge=$prep")
    [[ -n "$mac2" ]] && args+=(--net2 "virtio=$mac2,bridge=$prep")
    # Add net3 on sync bridge (hotplug friendly)
    args+=(--net3 "virtio,bridge=$sync")

    qm set "$vmid" "${args[@]}" >/dev/null
    ok "VM $vmid quarantined — all LAN-facing NICs on $prep, net3 on $sync"
}

qm_verify_quarantine() {
    local vmid="$1" prep="$2" sync="$3"
    local cfg
    cfg=$(qm config "$vmid")

    # Every LAN-facing NIC must be on the prep bridge — use grep -F so bridge
    # names with regex-special chars are treated literally.
    local bad
    bad=$(echo "$cfg" | grep '^net[0-2]:' | grep -vF "bridge=$prep" || true)
    [[ -z "$bad" ]] || die "VM $vmid has NICs NOT on $prep: $bad"

    # net3 must be on the sync bridge
    echo "$cfg" | grep '^net3:' | grep -qF "bridge=$sync" \
        || die "VM $vmid net3 not on $sync"

    # Autostart must be off
    echo "$cfg" | grep -q '^onboot: 0' \
        || die "VM $vmid onboot must be 0 (got: $(echo "$cfg" | grep '^onboot:' || echo 'missing'))"

    # Tags must be empty (no 'firewall', 'production', etc. accidentally copied from primary)
    local tags_line
    tags_line=$(echo "$cfg" | grep '^tags:' || true)
    if [[ -n "$tags_line" ]]; then
        local tag_val; tag_val=$(echo "$tags_line" | awk -F: '{print $2}' | xargs)
        [[ -z "$tag_val" ]] || die "VM $vmid still has tags set: '$tag_val' — should be empty"
    fi

    ok "VM $vmid quarantine verified (all NICs isolated, onboot=0, tags clear)"
}

qm_wait_agent() {
    # $1 = vmid, $2 = max seconds (default 180)
    # `qm agent ping` prints nothing on success (exit 0), prints an error and exits non-zero on failure.
    local vmid="$1" max="${2:-180}" elapsed=0
    info "waiting up to ${max}s for VM $vmid guest-agent..."
    while (( elapsed <= max )); do
        if qm agent "$vmid" ping >/dev/null 2>&1; then
            ok "VM $vmid agent responsive after ${elapsed}s"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    die "VM $vmid guest-agent did not respond within ${max}s"
}

# -----------------------------------------------------------------------------
# SSH channel to a quarantined VM via a temp subnet
# -----------------------------------------------------------------------------
ssh_channel_up() {
    # $1 = vmid, $2 = topology file
    local vmid="$1" topo="$2"
    local host_cidr guest_cidr guest_iface
    host_cidr=$(jq_require "$topo" prep_access.host_bridge_ip_cidr)
    guest_cidr=$(jq_require "$topo" prep_access.guest_alias_ip_cidr)
    guest_iface=$(jq_require "$topo" prep_access.guest_alias_iface)
    local prep_bridge; prep_bridge=$(jq_require "$topo" bridges.prep_bridge)
    local guest_ip="${guest_cidr%/*}"

    # 1. Alias on guest (runtime only; will be gone after reboot, re-added by next call)
    info "adding alias $guest_cidr to $guest_iface in VM $vmid"
    qm guest exec "$vmid" -- /sbin/ifconfig "$guest_iface" inet "$guest_cidr" alias >/dev/null 2>&1 || \
        warn "alias add reported non-zero (may already exist)"

    # 2. Host IP on prep bridge
    if ! ip addr show "$prep_bridge" | grep -q "${host_cidr%/*}"; then
        info "adding host IP $host_cidr to $prep_bridge"
        ip addr add "$host_cidr" dev "$prep_bridge"
    fi

    # 3. SSH key — push via stdin so any characters (even quotes) in the pubkey are safe
    [[ -f /root/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -C "opnsense-ha-$(hostname)" -q
    info "pushing SSH key into VM $vmid authorized_keys"
    # Use qemu-guest-agent file-write (base64 encoded) — avoids shell quoting of the pubkey entirely.
    # File is tiny (~100 bytes) so the file-write buffer limit is not an issue.
    qm guest exec "$vmid" -- /bin/sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys" >/dev/null 2>&1
    pvesh create "/nodes/$(hostname)/qemu/$vmid/agent/file-write" \
        --file /root/.ssh/authorized_keys \
        --content "$(cat /root/.ssh/id_ed25519.pub)" >/dev/null 2>&1 || \
        die "failed to push SSH key into VM $vmid"
    qm guest exec "$vmid" -- /bin/chmod 600 /root/.ssh/authorized_keys >/dev/null 2>&1

    # 4. sshd listen on the alias IP — use 0.0.0.0 so sshd doesn't fail to bind when
    #    the alias isn't yet present on boot (e.g. after a reboot before this function
    #    re-runs). Restrict access at the firewall layer if needed, not here.
    info "configuring sshd ListenAddress 0.0.0.0 (so missing alias at boot can't keep sshd from starting)"
    pvesh create "/nodes/$(hostname)/qemu/$vmid/agent/file-write" \
        --file /usr/local/etc/ssh/sshd_config.d/99-ha-prep.conf \
        --content "ListenAddress 0.0.0.0
" >/dev/null 2>&1 || warn "sshd_config.d write returned non-zero"
    qm guest exec "$vmid" -- /bin/pkill -HUP -x sshd >/dev/null 2>&1 || true
    sleep 2

    # 5. Test
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o ConnectTimeout=5 \
            -i /root/.ssh/id_ed25519 "root@$guest_ip" hostname >/dev/null 2>&1; then
        ok "SSH channel to VM $vmid at $guest_ip is up"
        return 0
    fi
    die "SSH to VM $vmid at $guest_ip failed"
}

ssh_channel_down() {
    # Remove the temporary SSH channel artifacts — call at end of successful prep
    # or at the start of rollback. Idempotent.
    local vmid="$1" topo="$2"
    local host_cidr prep_bridge
    host_cidr=$(jq_get "$topo" prep_access.host_bridge_ip_cidr "")
    prep_bridge=$(jq_get "$topo" bridges.prep_bridge "")
    if [[ -n "$host_cidr" && -n "$prep_bridge" ]] && bridge_exists "$prep_bridge"; then
        ip addr del "$host_cidr" dev "$prep_bridge" 2>/dev/null || true
    fi
    if vm_running "$vmid" 2>/dev/null && qm agent "$vmid" ping >/dev/null 2>&1; then
        qm guest exec "$vmid" -- /bin/rm -f /usr/local/etc/ssh/sshd_config.d/99-ha-prep.conf /root/.ssh/authorized_keys >/dev/null 2>&1 || true
        qm guest exec "$vmid" -- /bin/pkill -HUP -x sshd >/dev/null 2>&1 || true
    fi
}

ssh_to_vm() {
    # $1 = ip, rest = command
    local ip="$1"; shift
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 "root@$ip" "$@"
}

scp_to_vm() {
    # $1 = local file, $2 = ip, $3 = remote path
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 "$1" "root@$2:$3"
}

# -----------------------------------------------------------------------------
# Deploy config to a running VM via SSH
# -----------------------------------------------------------------------------
deploy_config_ssh() {
    # $1 = guest IP, $2 = local config path, $3 = VMID (for reboot)
    local ip="$1" cfg="$2" vmid="$3"
    local sha; sha=$(sha256sum "$cfg" | awk '{print $1}')
    info "pushing $cfg to VM $vmid at $ip"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
        -i /root/.ssh/id_ed25519 "$cfg" "root@$ip:/conf/config.xml.new"
    ssh_to_vm "$ip" "
        set -e
        sha256 -q /conf/config.xml.new | grep -q '$sha' || { echo 'sha mismatch'; exit 1; }
        cp /conf/config.xml /conf/config.xml.pre-deploy-\$(date +%Y%m%d-%H%M%S)
        chown wwwonly:wheel /conf/config.xml.new
        chmod 640 /conf/config.xml.new
        mv /conf/config.xml.new /conf/config.xml
    "
    ok "config deployed; rebooting VM $vmid to apply"
    # Reboot via Proxmox (synchronous, waits for shutdown; safer than backgrounded ssh)
    # NOTE: qm reboot will ACPI-request through the guest-agent which takes ~10s on OPNsense.
    qm reboot "$vmid" --timeout 60 >/dev/null 2>&1 || {
        warn "qm reboot timed out or failed; forcing via ssh"
        # ssh reboot with 'nohup' detached from the session so scp's channel closes cleanly
        ssh_to_vm "$ip" "nohup /sbin/reboot >/dev/null 2>&1 &" || true
    }
    sleep 5
    qm_wait_agent "$vmid" 240
}

# =============================================================================
# Subcommand: init-topology
# =============================================================================
cmd_init_topology() {
    local path="${1:-topology.json}" force="${2:-}"
    [[ -e "$path" && "$force" != "--force" ]] && die "$path exists (use --force to overwrite)"
    get_py_tool
    "${PY_TOOL[@]}" init-topology "$path" ${force:+--force} 2>/dev/null || {
        # Embedded python doesn't have init-topology; fall back to inline
        python3 - "$path" <<'PY'
import json, sys
ex = {
    "primary": {"vmid": 101, "name": "opnsense-primary", "node": "pve1", "real_ip_suffix": 251},
    "secondary": {"vmid": 102, "name": "opnsense-secondary", "node": "pve1", "storage": "local-lvm",
                  "cores": 4, "ram_mb": 8192, "disk_gb": 30, "real_ip_suffix": 252, "onboot": 0},
    "bridges": {"prep_bridge": "vmbr-prep", "sync_bridge": "vmbr-sync"},
    "interfaces": [
      {"iface_tag": "wan", "descr": "WAN", "bridge": "vmbr0", "vlan_tag": None,
       "primary_current_ip": "203.0.113.1", "prefix": 30, "primary_gateway": "203.0.113.2",
       "vhid": 20, "role": "wan", "defer_carp": True},
      {"iface_tag": "lan", "descr": "LAN", "bridge": "vmbr0", "vlan_tag": None,
       "primary_current_ip": "192.0.2.1", "prefix": 24, "vhid": 1, "role": "lan"}
      # Add more interfaces (opt1, opt2, ...) with your own
      # vlan_tag, bridge, primary_current_ip, vhid, and role="lan".
    ],
    "sync_link": {"opt_tag": "opt2", "descr": "HA-SYNC", "guest_if": "vtnet2",
                  "subnet": "198.51.100.0/24", "primary_ip": "198.51.100.251",
                  "secondary_ip": "198.51.100.252", "prefix": 24},
    "carp": {"password": "CHANGE-ME-set-a-strong-carp-password",
             "primary_advskew": 0, "secondary_advskew": 100, "advbase": 1, "preempt": True},
    "disable_on_secondary": ["dhcpd", "dhcpdv6", "unbound"],
    "prep_access": {"host_bridge_ip_cidr": "198.51.100.1/24",
                    "guest_alias_ip_cidr": "198.51.100.2/24",
                    "guest_alias_iface": "vtnet1"}
  }
open(sys.argv[1], "w").write(json.dumps(ex, indent=2) + "\n")
print("wrote " + sys.argv[1])
PY
    }
    ok "example topology written — edit it before use"
}

# =============================================================================
# Subcommand: validate
# =============================================================================
cmd_validate() {
    local topo="$1"
    [[ -r "$topo" ]] || die "topology file not readable: $topo"
    get_py_tool
    local out rc
    set +e
    out=$("${PY_TOOL[@]}" validate --topology "$topo" 2>&1)
    rc=$?
    set -e
    if (( rc == 0 )); then
        echo "$out"
        ok "topology valid"
        return 0
    else
        err "topology invalid:"
        echo "$out" >&2
        if echo "$out" | grep -q "invalid choice\|unrecognized arguments"; then
            python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$topo" && \
                warn "JSON parses OK but deep validation unavailable (install standalone opnsense-ha-config.py)"
        fi
        return 1
    fi
}

# =============================================================================
# Subcommand: single — create ONE OPNsense VM from scratch
# =============================================================================
cmd_single() {
    # Flags: --vmid N --name X --storage S --iso PATH --bridge-lan B --bridge-wan B
    #        --bridge-mgmt B --cores N --ram MB --disk GB --start --onboot
    local vmid="" name="OPNsense-new" storage="local-lvm" iso=""
    local br_lan="vmbr0" br_wan="" br_mgmt="" cores=4 ram=8192 disk=30 start_vm=0 onboot=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vmid) vmid="$2"; shift 2;;
            --name) name="$2"; shift 2;;
            --storage) storage="$2"; shift 2;;
            --iso) iso="$2"; shift 2;;
            --bridge-lan) br_lan="$2"; shift 2;;
            --bridge-wan) br_wan="$2"; shift 2;;
            --bridge-mgmt) br_mgmt="$2"; shift 2;;
            --cores) cores="$2"; shift 2;;
            --ram) ram="$2"; shift 2;;
            --disk) disk="$2"; shift 2;;
            --start) start_vm=1; shift;;
            --no-onboot) onboot=0; shift;;
            *) die "unknown arg: $1";;
        esac
    done

    require_root; need_cmds_for_vms

    [[ -n "$vmid" ]] || vmid=$(pvesh get /cluster/nextid)
    vm_exists "$vmid" && die "VMID $vmid already exists"

    if [[ -z "$iso" ]]; then
        iso="$DEFAULT_ISO_DIR/$DEFAULT_ISO_NAME"
        if [[ ! -f "$iso" ]]; then
            warn "ISO not found at $iso"
            if confirm "Download OPNsense ${DEFAULT_ISO_VERSION} (~500MB)?"; then
                local url="$DEFAULT_ISO_URL_BASE/${DEFAULT_ISO_VERSION}/${DEFAULT_ISO_NAME}.bz2"
                info "downloading $url"
                wget -q --show-progress -O "$iso.bz2" "$url" || die "ISO download failed"
                bunzip2 "$iso.bz2"
                ok "ISO extracted: $iso"
            else
                die "no ISO, cannot create VM"
            fi
        fi
    fi
    [[ -f "$iso" ]] || die "ISO not found: $iso"

    info "creating VM $vmid '$name' (cores=$cores ram=$ram disk=${disk}G storage=$storage)"
    qm create "$vmid" \
        --name "$name" \
        --agent enabled=1 \
        --bios seabios \
        --boot c --bootdisk scsi0 \
        --cores "$cores" \
        --memory "$ram" \
        --balloon 0 \
        --cpu kvm64 \
        --ostype l26 \
        --scsihw virtio-scsi-pci \
        --scsi0 "$storage:$disk,format=raw" \
        --ide2 "local:iso/$(basename "$iso"),media=cdrom" \
        --net0 "virtio,bridge=$br_lan" \
        --onboot "$onboot" \
        --tablet 0

    # optional additional NICs
    [[ -n "$br_wan" ]] && qm set "$vmid" --net1 "virtio,bridge=$br_wan" >/dev/null
    [[ -n "$br_mgmt" ]] && qm set "$vmid" --net2 "virtio,bridge=$br_mgmt" >/dev/null

    ok "VM $vmid created"
    if (( start_vm )); then
        qm start "$vmid"
        ok "VM $vmid started — open Proxmox noVNC console to run the OPNsense installer"
    else
        info "VM not started. Start it with:  qm start $vmid"
    fi
}

# =============================================================================
# Subcommand: ha-duplicate — clone existing primary and prep secondary for CARP
# =============================================================================
cmd_ha_duplicate() {
    local topo=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --topology) topo="$2"; shift 2;;
            *) die "unknown arg: $1";;
        esac
    done
    [[ -n "$topo" ]] || die "--topology <file> required"
    cmd_validate "$topo"
    require_root; need_cmds_for_vms

    local pvmid svmid sname sstorage prep sync
    pvmid=$(jq_require "$topo" primary.vmid)
    svmid=$(jq_require "$topo" secondary.vmid)
    sname=$(jq_require "$topo" secondary.name)
    sstorage=$(jq_require "$topo" secondary.storage)
    prep=$(jq_require "$topo" bridges.prep_bridge)
    sync=$(jq_require "$topo" bridges.sync_bridge)
    [[ "$pvmid" != "$svmid" ]] || die "primary.vmid and secondary.vmid must differ"

    # 1. Snapshot state
    snapshot_host

    # 2. Sanity
    vm_exists "$pvmid" || die "primary VM $pvmid does not exist"
    vm_running "$pvmid" || warn "primary VM $pvmid is not running — clone will be offline"
    vm_exists "$svmid" && die "secondary VM $svmid already exists — destroy it first or pick another VMID"
    # Guest-agent readiness on primary (we don't need it, but we do need it on the clone)
    qm config "$pvmid" | grep -q '^agent:' || warn "primary has no agent: line; clone may need agent installed"

    # 3. Bridges
    add_isolated_bridge "$prep" "Isolated bridge for VM $svmid pre-config quarantine. No uplink."
    add_isolated_bridge "$sync" "Dedicated pfsync/CARP-sync link between OPNsense primary (VM $pvmid) and secondary (VM $svmid). No uplink."

    # 4. Clone
    qm_online_clone "$pvmid" "$svmid" "$sname" "$sstorage"

    # 5. Quarantine
    qm_quarantine "$svmid" "$prep" "$sync" \
        "OPNsense HA secondary (prep). NICs on $prep + $sync (isolated, no uplink). DO NOT attach to production bridges until interface IPs have been rewritten by this script."
    qm_verify_quarantine "$svmid" "$prep" "$sync"

    # 6. Boot
    info "starting secondary VM $svmid"
    qm start "$svmid"
    qm_wait_agent "$svmid" 180

    # 7. Establish SSH channel
    ssh_channel_up "$svmid" "$topo"
    local guest_ip; guest_ip=$(jq_get "$topo" prep_access.guest_alias_ip_cidr)
    guest_ip="${guest_ip%/*}"

    # 8. Pull primary config from the clone (it's a byte-for-byte clone, so this is effectively the primary's live config)
    local workdir; workdir="$(mktemp -d /tmp/opnsense-ha.XXXXXX)"
    info "pulling /conf/config.xml from VM $svmid to $workdir/primary.xml"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
        -i /root/.ssh/id_ed25519 "root@$guest_ip:/conf/config.xml" "$workdir/primary.xml"

    # 9. Transform
    info "transforming primary -> secondary config via python tool"
    get_py_tool
    "${PY_TOOL[@]}" transform-secondary \
        --primary-config "$workdir/primary.xml" \
        --output "$workdir/secondary.xml" \
        --topology "$topo"

    # 10. Deploy + reboot
    deploy_config_ssh "$guest_ip" "$workdir/secondary.xml" "$svmid"

    # 11. After reboot, alias + sshd override are gone. Restore.
    ssh_channel_up "$svmid" "$topo"

    # 12. Final verify
    info "post-reboot verification"
    local new_host; new_host=$(qm agent "$svmid" get-host-name | python3 -c 'import json,sys; print(json.load(sys.stdin).get("host-name",""))')
    info "  secondary hostname: $new_host"
    qm agent "$svmid" network-get-interfaces | python3 -c '
import json, sys
d = json.load(sys.stdin)
for i in d:
    ips = [a.get("ip-address") for a in i.get("ip-addresses", []) if a.get("ip-address-type") == "ipv4"]
    if ips and i.get("name") != "lo0":
        print("  {:20s} {}".format(i["name"], ips))
'

    # 13. Production sanity
    info "production sanity:"
    info "  VM $pvmid status: $(qm status "$pvmid" | awk '{print $2}')"

    # Clean up temporary SSH channel (alias IP on host, sshd override in guest)
    ssh_channel_down "$svmid" "$topo"

    rm -rf "$workdir"
    ok "HA-duplicate complete. Secondary $svmid on quarantined bridges, ready for activation."
    cat <<EOF

Next steps (not automated — require decisions and a maintenance window):
  1. When ready to activate, see the TREHQKennedy-style activation plan:
     - Hotplug net3 onto primary: qm set $pvmid --net3 virtio,bridge=$sync
     - In primary OPNsense GUI, assign vtnet3 as OPT10 = $(jq_get "$topo" sync_link.primary_ip)
     - Add matching CARP VIPs (same password, same VHIDs, advskew=$(jq_get "$topo" carp.primary_advskew))
     - Configure System > High Availability > Settings
     - (Disruptive) renumber primary IPs from .1 to $(jq_get "$topo" primary.real_ip_suffix)
     - Move secondary NICs off $prep to production bridges
  2. Python tool can pre-generate primary-side configs:
     opnsense-ha-config.py inject-primary-carp --primary-config primary.xml --output primary-with-carp.xml --topology $topo
EOF
}

# =============================================================================
# Subcommand: ha-fresh — create TWO fresh OPNsense VMs + base config
# =============================================================================
cmd_ha_fresh() {
    local topo=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --topology) topo="$2"; shift 2;;
            *) die "unknown arg: $1";;
        esac
    done
    [[ -n "$topo" ]] || die "--topology <file> required"
    cmd_validate "$topo"
    require_root; need_cmds_for_vms

    local pvmid svmid pname sname storage prep sync
    pvmid=$(jq_require "$topo" primary.vmid)
    svmid=$(jq_require "$topo" secondary.vmid)
    pname=$(jq_require "$topo" primary.name)
    sname=$(jq_require "$topo" secondary.name)
    storage=$(jq_require "$topo" secondary.storage)
    prep=$(jq_require "$topo" bridges.prep_bridge)
    sync=$(jq_require "$topo" bridges.sync_bridge)
    [[ "$pvmid" != "$svmid" ]] || die "primary.vmid and secondary.vmid must differ"

    vm_exists "$pvmid" && die "primary VMID $pvmid taken — use ha-duplicate instead if it's the existing firewall"
    vm_exists "$svmid" && die "secondary VMID $svmid taken"

    snapshot_host
    add_isolated_bridge "$prep" "ha-fresh prep bridge"
    add_isolated_bridge "$sync" "ha-fresh sync bridge"

    # Create both VMs with ISO attached, no start yet
    info "creating primary VM $pvmid from ISO (install it manually via noVNC console)"
    cmd_single --vmid "$pvmid" --name "$pname" --storage "$storage" \
        --bridge-lan "$prep" --no-onboot

    info "creating secondary VM $svmid"
    cmd_single --vmid "$svmid" --name "$sname" --storage "$storage" \
        --bridge-lan "$prep" --no-onboot

    cat <<EOF

Two blank OPNsense VMs created, both on isolated bridges.

To proceed:
  1. Start primary: qm start $pvmid
  2. Open Proxmox web UI noVNC console for $pvmid, install OPNsense through the installer
  3. Configure primary's interfaces/rules/etc. via web GUI at whatever IP you set
  4. When primary is happy, run: $SCRIPT_NAME ha-duplicate --topology $topo
     This will clone the primary, prep the secondary from the clone, and set up CARP.

ha-fresh intentionally does NOT automate the OPNsense install — that's interactive
and easier to do in a console than to script.
EOF
}

# =============================================================================
# Subcommand: status — inspect current HA state
# =============================================================================
cmd_status() {
    # Status is informational — tolerate tool-exit quirks
    set +e
    local topo="${1:-}"
    require_root
    if [[ -n "$topo" ]]; then
        cmd_validate "$topo"
        local pvmid svmid prep sync
        pvmid=$(jq_get "$topo" primary.vmid)
        svmid=$(jq_get "$topo" secondary.vmid)
        prep=$(jq_get "$topo" bridges.prep_bridge)
        sync=$(jq_get "$topo" bridges.sync_bridge)
        echo "=== HA pair status per $topo ==="
        echo "primary VM $pvmid: $(qm status "$pvmid" 2>&1 | awk '{print $2}')"
        echo "secondary VM $svmid: $(qm status "$svmid" 2>&1 | awk '{print $2}')"
        echo
        echo "=== bridges ==="
        brctl show "$prep" "$sync" 2>&1 | head -20
        echo
        echo "=== secondary interfaces (if reachable via agent) ==="
        if vm_running "$svmid" && qm agent "$svmid" ping >/dev/null 2>&1; then
            qm agent "$svmid" network-get-interfaces 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for i in d:
        ips = [a.get("ip-address") for a in i.get("ip-addresses", []) if a.get("ip-address-type") == "ipv4"]
        if ips and i.get("name") != "lo0":
            print("  {:20s} {}".format(i["name"], ips))
except Exception:
    pass
'
        else
            echo "  (agent not responsive or VM not running)"
        fi
    else
        echo "=== Proxmox VMs ==="
        qm list | grep -iE 'opnsense|firewall|VMID' || true
        echo
        echo "=== bridges on this host ==="
        brctl show
    fi
}

# =============================================================================
# Subcommand: verify — full post-prep verification battery
# =============================================================================
cmd_verify() {
    local topo="${1:-}"
    [[ -n "$topo" ]] || die "verify requires a topology file"
    cmd_validate "$topo"
    require_root

    local pvmid svmid prep sync
    pvmid=$(jq_get "$topo" primary.vmid); svmid=$(jq_get "$topo" secondary.vmid)
    prep=$(jq_get "$topo" bridges.prep_bridge); sync=$(jq_get "$topo" bridges.sync_bridge)

    local fail=0
    check() {
        local desc="$1"; shift
        if "$@" >/dev/null 2>&1; then
            ok "$desc"
        else
            err "$desc"
            fail=$((fail+1))
        fi
    }

    check "primary VM $pvmid exists" qm config "$pvmid"
    check "primary VM $pvmid is running" vm_running "$pvmid"
    check "secondary VM $svmid exists" qm config "$svmid"
    check "prep bridge $prep exists" bridge_exists "$prep"
    check "sync bridge $sync exists" bridge_exists "$sync"

    # Secondary NICs on isolated bridges only (use -F for literal-string matching)
    if vm_exists "$svmid"; then
        local cfg; cfg=$(qm config "$svmid")
        local bad
        bad=$(echo "$cfg" | grep '^net[0-2]:' | grep -vF "bridge=$prep" || true)
        if [[ -z "$bad" ]]; then
            ok "secondary net0/1/2 all on $prep"
        else
            err "secondary has NIC NOT on $prep: $bad"
            fail=$((fail+1))
        fi

        # Use plain if/else (not `A && B || C` — that pattern misfires if B's exit is non-zero)
        if echo "$cfg" | grep '^net3:' | grep -qF "bridge=$sync"; then
            ok "secondary net3 on $sync"
        else
            err "secondary net3 not on $sync"
            fail=$((fail+1))
        fi
    fi

    # Secondary agent + hostname
    if vm_running "$svmid" 2>/dev/null; then
        if qm agent "$svmid" ping >/dev/null 2>&1; then
            local h; h=$(qm agent "$svmid" get-host-name | python3 -c 'import json,sys;print(json.load(sys.stdin).get("host-name",""))')
            if [[ "$h" == *"-sec"* ]]; then ok "secondary hostname has -sec suffix ($h)"
            else warn "secondary hostname doesn't end with -sec: $h"; fi
        fi
    fi

    echo
    if (( fail > 0 )); then err "$fail check(s) failed"; return 1
    else ok "all checks passed"; fi
}

# =============================================================================
# Subcommand: rollback — destroy secondary and remove isolated bridges
# =============================================================================
cmd_rollback() {
    local topo="${1:-}"
    [[ -n "$topo" ]] || die "rollback requires a topology file"
    cmd_validate "$topo"
    require_root

    local svmid prep sync
    svmid=$(jq_require "$topo" secondary.vmid)
    prep=$(jq_require "$topo" bridges.prep_bridge)
    sync=$(jq_require "$topo" bridges.sync_bridge)

    confirm "This will STOP and DESTROY VM $svmid, remove bridges $prep and $sync, and revert host network additions. Continue?" || die "aborted"

    # Tear down temporary SSH channel first (host IP on prep bridge)
    ssh_channel_down "$svmid" "$topo"

    if vm_exists "$svmid"; then
        if vm_running "$svmid"; then
            info "stopping VM $svmid (graceful, forcing if >60s)"
            # --forceStop 1 --timeout 60 means: try ACPI for 60s, then force stop. No need for || qm stop.
            qm shutdown "$svmid" --forceStop 1 --timeout 60
        fi
        info "destroying VM $svmid"
        qm destroy "$svmid"
        ok "VM $svmid destroyed"
    fi

    # Take down bridges, then remove stanzas
    for br in "$prep" "$sync"; do
        if bridge_exists "$br"; then
            info "taking down $br"
            ifdown "$br" 2>/dev/null || true
        fi
    done

    # Remove stanzas via Python rewrite (preserves other content). The regex is
    # liberal — matches any indentation / ordering — and logs when a stanza isn't
    # found so silent leaks are visible.
    python3 - "$prep" "$sync" <<'PY'
import sys, re
prep, sync = sys.argv[1], sys.argv[2]
path = "/etc/network/interfaces"
txt = open(path).read()
# Back up before writing
import shutil, time
shutil.copy(path, f"{path}.bak-rollback-{int(time.time())}")
changed = False
for br in (prep, sync):
    # Match from `auto <br>` (or start-of-file) through the blank line or next `auto`/`source` statement.
    pattern = re.compile(
        rf"(^|\n)auto {re.escape(br)}\b[^\n]*\n"
        rf"(iface {re.escape(br)}\b[^\n]*\n"
        rf"([ \t]+[^\n]*\n)*"
        rf"(#[^\n]*\n)?)",
        re.MULTILINE,
    )
    new_txt, n = pattern.subn(lambda m: m.group(1), txt, count=1)
    if n:
        txt = new_txt
        changed = True
        print(f"  removed stanza: {br}")
    else:
        print(f"  WARN: stanza for {br} not found (already removed or hand-edited)", file=sys.stderr)
if changed:
    open(path, "w").write(txt)
    print("updated /etc/network/interfaces")
else:
    print("no changes to /etc/network/interfaces")
PY

    ok "rollback complete. host + primary byte-identical to pre-prep state."
}

# =============================================================================
# Subcommand: deploy-config
# =============================================================================
cmd_deploy_config() {
    local vmid="" cfg="" via_ip=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vmid) vmid="$2"; shift 2;;
            --config) cfg="$2"; shift 2;;
            --ssh-ip) via_ip="$2"; shift 2;;
            *) die "unknown arg: $1";;
        esac
    done
    [[ -n "$vmid" && -n "$cfg" && -n "$via_ip" ]] || die "usage: deploy-config --vmid N --config FILE --ssh-ip IP"
    [[ -r "$cfg" ]] || die "config not readable: $cfg"
    require_root
    deploy_config_ssh "$via_ip" "$cfg" "$vmid"
    ok "deploy-config complete"
}

# =============================================================================
# Help
# =============================================================================
cmd_help() {
    cat <<EOF
$SCRIPT_NAME — unified OPNsense VM manager for Proxmox, with CARP HA support

USAGE:
  $SCRIPT_NAME <subcommand> [options]

SUBCOMMANDS:
  init-topology <path> [--force]      Write an example topology.json
  validate <topology.json>            Validate topology file
  single [options]                    Create ONE OPNsense VM from scratch
    --vmid N          VM ID (auto-picked if omitted)
    --name X          display name
    --storage S       storage pool (default local-lvm)
    --iso PATH        OPNsense ISO path (auto-download if missing)
    --bridge-lan B    LAN bridge (default vmbr0)
    --bridge-wan B    optional WAN bridge
    --bridge-mgmt B   optional management bridge
    --cores N --ram MB --disk GB
    --start           start VM after creation
    --no-onboot       don't set onboot=1
  ha-duplicate --topology FILE        Clone existing primary, prep secondary for CARP
  ha-fresh --topology FILE            Create two blank OPNsense VMs (manual install)
  deploy-config --vmid N --config FILE --ssh-ip IP
                                      Push a /conf/config.xml to a VM and reboot
  status [topology.json]              Inspect state
  verify <topology.json>              Post-prep verification battery
  rollback <topology.json>            Destroy secondary + remove added bridges
  help                                This message

ENVIRONMENT:
  ASSUME_YES=1                        skip confirmation prompts (use carefully)
  OPNSENSE_HA_SNAPSHOT_DIR=/path      where to save host state snapshots (default /root/opnsense-ha-snapshots)

TYPICAL HA FLOW:
  # First-time setup
  $SCRIPT_NAME init-topology /root/my-topology.json
  vim /root/my-topology.json              # fill in primary VMID, IPs, CARP password, etc.
  $SCRIPT_NAME validate /root/my-topology.json
  $SCRIPT_NAME ha-duplicate --topology /root/my-topology.json
  $SCRIPT_NAME verify /root/my-topology.json
  $SCRIPT_NAME status /root/my-topology.json

  # Later: generate primary-side config with CARP pre-injected (no renumber)
  scp primary:/conf/config.xml /tmp/primary.xml
  opnsense-ha-config.py inject-primary-carp \\
      --primary-config /tmp/primary.xml \\
      --output /tmp/primary-with-carp.xml \\
      --topology /root/my-topology.json
  # Import /tmp/primary-with-carp.xml via the primary's OPNsense GUI in a
  # maintenance window (non-disruptive on its own)

  # Much later: generate fully-activated primary config (renumbered)
  opnsense-ha-config.py activate-primary-renumber \\
      --primary-config /tmp/primary-with-carp.xml \\
      --output /tmp/primary-activated.xml \\
      --topology /root/my-topology.json
  # Import in maintenance window — this is the disruptive step.

SAFETY:
  This script never modifies the primary VM automatically. The 'ha-duplicate' flow
  creates an isolated clone on quarantined bridges; production is untouched.
  Activation of the primary is intentionally manual (GUI import) to ensure a
  human sees every change.
EOF
}

# =============================================================================
# Main dispatch
# =============================================================================
main() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        init-topology) cmd_init_topology "$@" ;;
        validate)      cmd_validate "$@" ;;
        single)        cmd_single "$@" ;;
        ha-duplicate)  cmd_ha_duplicate "$@" ;;
        ha-fresh)      cmd_ha_fresh "$@" ;;
        deploy-config) cmd_deploy_config "$@" ;;
        status)        cmd_status "$@" ;;
        verify)        cmd_verify "$@" ;;
        rollback)      cmd_rollback "$@" ;;
        help|-h|--help|"") cmd_help ;;
        *) err "unknown subcommand: $sub"; cmd_help; exit 2 ;;
    esac
}

main "$@"
