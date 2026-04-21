#!/usr/bin/env python3
"""
opnsense-ha-config.py

Transform OPNsense config.xml files for CARP HA. Pure Python stdlib — no deps.
Runs on any machine with Python 3.8+, not just the Proxmox host.

Typical flow:
    # 1. Pull the primary's current config from the running firewall
    scp root@primary-firewall:/conf/config.xml  primary.xml

    # 2. Generate a secondary config (renumbered, services disabled, CARP VIPs,
    #    pfsync pre-configured) from it using a topology file
    ./opnsense-ha-config.py transform-secondary \\
        --primary-config primary.xml \\
        --output       secondary.xml \\
        --topology     topology.json

    # 3. Optionally generate a primary-side config with CARP VIPs added
    #    (non-disruptive: primary still owns .1 as its real IP)
    ./opnsense-ha-config.py inject-primary-carp \\
        --primary-config primary.xml \\
        --output       primary-with-carp.xml \\
        --topology     topology.json

    # 4. Later, when ready to flip: renumber primary's real IPs to .251 (disruptive)
    ./opnsense-ha-config.py activate-primary-renumber \\
        --primary-config primary-with-carp.xml \\
        --output       primary-activated.xml \\
        --topology     topology.json

    # 5. Deploy each config.xml to its respective firewall, reboot.

The topology.json file describes the HA pair's interface layout, CARP VHIDs,
sync link, password. Use `init-topology <path>` to generate a commented template.
"""

import argparse
import json
import re
import sys
import uuid
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape


def _xe(s):
    """XML-escape a string for safe insertion as element text. None -> ''."""
    if s is None:
        return ""
    return xml_escape(str(s), {'"': "&quot;", "'": "&apos;"})


# =============================================================================
# Topology schema and example
# =============================================================================

EXAMPLE_TOPOLOGY = {
    "_comment_1": "OPNsense CARP HA topology. Add as many interfaces as you need — copy any of the example entries below.",
    "_comment_2": "All addresses are documentation-only placeholders (RFC 5737 / RFC 3849). Replace every value with your real network.",
    "_comment_3": "Each interface needs: iface_tag, descr, bridge, vlan_tag (or None), primary_current_ip, prefix, vhid, role. Add an 'ipv6' block for IPv6 CARP.",

    "primary": {
        "vmid": 101,
        "name": "opnsense-primary",
        "node": "pve1",
        "real_ip_suffix": 251,
        "_comment": "final octet for primary's real IP after activation (e.g. 251 or 2)"
    },

    "secondary": {
        "vmid": 102,
        "name": "opnsense-secondary",
        "node": "pve1",
        "storage": "local-lvm",
        "cores": 4,
        "ram_mb": 8192,
        "disk_gb": 30,
        "real_ip_suffix": 252,
        "onboot": 0
    },

    "bridges": {
        "prep_bridge": "vmbr-prep",
        "_prep_comment": "isolated bridge, no uplink, holds secondary's LAN-facing NICs during prep",
        "sync_bridge": "vmbr-sync",
        "_sync_comment": "isolated bridge, no uplink, dedicated pfsync/CARP-sync link between the two VMs"
    },

    "interfaces": [
        # --- WAN: untagged, on the uplink bridge. Use defer_carp=True on a /30. -----
        {
            "iface_tag": "wan",
            "descr": "WAN",
            "bridge": "vmbr0",
            "vlan_tag": None,
            "primary_current_ip": "203.0.113.1",
            "prefix": 30,
            "primary_gateway": "203.0.113.2",
            "vhid": 20,
            "role": "wan",
            "defer_carp": True,
            "_defer_comment": "set true when ISP block is /30 — no room for a CARP VIP until a larger block is delivered"
        },

        # --- LAN: untagged, shares the uplink bridge. CARP VIP = the gateway clients already use. -----
        {
            "iface_tag": "lan",
            "descr": "LAN",
            "bridge": "vmbr0",
            "vlan_tag": None,
            "primary_current_ip": "192.0.2.1",
            "prefix": 24,
            "vhid": 1,
            "role": "lan"
        },

        # --- OPT1: a VLAN-tagged interface (e.g. guest/IoT/printers). Copy this block --
        # --- for every VLAN, changing iface_tag, descr, vlan_tag, IP, and vhid. --------
        {
            "iface_tag": "opt1",
            "descr": "EXAMPLE_VLAN_10",
            "bridge": "vmbr0",
            "vlan_tag": 10,
            "primary_current_ip": "192.0.2.129",
            "prefix": 25,
            "vhid": 10,
            "role": "lan"
        },

        # --- OPT2: a different physical bridge AND IPv6 CARP. The 'ipv6' block ---------
        # --- is optional; include it only on interfaces that run IPv6. -----------------
        {
            "iface_tag": "opt2",
            "descr": "EXAMPLE_MGMT",
            "bridge": "vmbr1",
            "vlan_tag": None,
            "primary_current_ip": "192.0.2.193",
            "prefix": 26,
            "vhid": 2,
            "role": "lan",
            "ipv6": {
                "_comment": "Per-interface IPv6 CARP. carp_vip is what clients use as gateway; secondary_ip is the backup firewall's real address on this segment.",
                "primary_current_ip": "2001:db8:1::1",
                "secondary_ip":       "2001:db8:1::3",
                "carp_vip":           "2001:db8:1::1",
                "prefix": 64,
                "vhid": 2
            }
        }

        # Add more interfaces here (opt3, opt4, ...) by copying one of the blocks
        # above and adjusting iface_tag, descr, bridge, vlan_tag, primary_current_ip,
        # prefix, and vhid. Every VHID must be unique per physical/VLAN segment.
    ],

    "sync_link": {
        "opt_tag": "opt3",
        "descr": "HA-SYNC",
        "guest_if": "vtnet3",
        "subnet": "198.51.100.0/24",
        "primary_ip": "198.51.100.251",
        "secondary_ip": "198.51.100.252",
        "prefix": 24
    },

    "carp": {
        "password": "CHANGE-ME-set-a-strong-carp-password",
        "_password_comment": "MUST be replaced. Identical on both firewalls per VHID; one password for all VIPs is fine.",
        "primary_advskew": 0,
        "secondary_advskew": 100,
        "advbase": 1,
        "preempt": True
    },

    "disable_on_secondary": [
        "dhcpd",
        "dhcpdv6",
        "unbound"
    ],

    "prep_access": {
        "_comment": "temporary host<->guest link during prep; pick a subnet unused elsewhere",
        "host_bridge_ip_cidr": "198.51.100.1/24",
        "guest_alias_ip_cidr": "198.51.100.2/24",
        "guest_alias_iface": "vtnet1"
    }
}


# =============================================================================
# Topology loading / validation
# =============================================================================

def strip_comments(obj):
    """Recursively remove keys starting with '_' from dicts (our comment convention)."""
    if isinstance(obj, dict):
        return {k: strip_comments(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [strip_comments(x) for x in obj]
    return obj


def load_topology(path):
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        raise RuntimeError(f"topology file not found: {path}")
    except PermissionError:
        raise RuntimeError(f"topology file not readable (permission denied): {path}")
    except json.JSONDecodeError as e:
        raise RuntimeError(f"topology file is not valid JSON ({path}): {e}")
    topo = strip_comments(raw)
    validate_topology(topo)
    return topo


def _read_xml(path):
    try:
        return Path(path).read_text()
    except FileNotFoundError:
        raise RuntimeError(f"config file not found: {path}")
    except PermissionError:
        raise RuntimeError(f"config file not readable (permission denied): {path}")


def validate_topology(topo):
    """Strict validation of topology dict. Raises ValueError with specific message on problem."""
    errors = []

    # Top-level keys
    required = {"primary", "secondary", "bridges", "interfaces", "sync_link", "carp"}
    missing = required - set(topo.keys())
    if missing:
        errors.append(f"missing top-level keys: {sorted(missing)}")

    # Primary / secondary VMID sanity
    for role in ("primary", "secondary"):
        if role in topo:
            if "vmid" not in topo[role]:
                errors.append(f"{role}.vmid missing")
            elif not isinstance(topo[role]["vmid"], int):
                errors.append(f"{role}.vmid must be int")
            if "real_ip_suffix" in topo[role] and not (0 < topo[role]["real_ip_suffix"] < 255):
                errors.append(f"{role}.real_ip_suffix must be 1-254")

    if "primary" in topo and "secondary" in topo:
        if topo["primary"].get("vmid") == topo["secondary"].get("vmid"):
            errors.append("primary.vmid and secondary.vmid collide")
        if topo["primary"].get("real_ip_suffix") == topo["secondary"].get("real_ip_suffix"):
            errors.append("primary.real_ip_suffix and secondary.real_ip_suffix collide")

    # Interface uniqueness
    seen_tags = set()
    seen_vhids = set()
    for i, iface in enumerate(topo.get("interfaces", [])):
        if "iface_tag" not in iface:
            errors.append(f"interfaces[{i}].iface_tag missing"); continue
        if iface["iface_tag"] in seen_tags:
            errors.append(f"interfaces[{i}].iface_tag '{iface['iface_tag']}' duplicated")
        seen_tags.add(iface["iface_tag"])

        for k in ("primary_current_ip", "prefix", "vhid", "role"):
            if k not in iface:
                errors.append(f"interfaces[{i}] '{iface.get('iface_tag')}' missing '{k}'")

        # VHID collision check — VHIDs must be unique per broadcast domain. We can't
        # precisely compute broadcast domains from the topology alone (parent iface +
        # VLAN tag), so we treat the entire topology as one domain. Over-strict but
        # safe; if you genuinely need VHID reuse across segregated VLANs, split into
        # two topology files.
        if iface.get("vhid") is not None:
            if iface["vhid"] in seen_vhids and not iface.get("defer_carp"):
                errors.append(f"interfaces[{i}] vhid {iface['vhid']} duplicated (collision)")
            seen_vhids.add(iface["vhid"])

        if iface.get("ipv6"):
            ipv6 = iface["ipv6"]
            # IPv6 block must be explicit about primary_current_ip, secondary_ip, carp_vip
            # and prefix / vhid. Auto-derivation of IPv6 host parts is a bug factory.
            for k in ("primary_current_ip", "secondary_ip", "carp_vip", "prefix", "vhid"):
                if k not in ipv6:
                    errors.append(f"interfaces[{i}].ipv6 missing '{k}'")

    # Sync link
    sync = topo.get("sync_link", {})
    for k in ("opt_tag", "guest_if", "primary_ip", "secondary_ip", "prefix"):
        if k not in sync:
            errors.append(f"sync_link.{k} missing")
    if sync.get("primary_ip") == sync.get("secondary_ip"):
        errors.append("sync_link.primary_ip and secondary_ip collide")

    # CARP
    carp = topo.get("carp", {})
    if "password" not in carp or not carp["password"]:
        errors.append("carp.password missing or empty")
    elif carp["password"].startswith("CHANGE-ME"):
        errors.append("carp.password is still the placeholder — set a real password in the topology file")
    if carp.get("primary_advskew") == carp.get("secondary_advskew"):
        errors.append("carp.primary_advskew must differ from carp.secondary_advskew")

    if errors:
        msg = "Topology validation failed:\n  - " + "\n  - ".join(errors)
        raise ValueError(msg)


# =============================================================================
# XML transforms — string-based, scoped to parent blocks to avoid cross-matches
# =============================================================================

def _find_block(xml, open_tag, close_tag, hint=None):
    """Locate (start_idx, end_idx) of a block like '<foo>...</foo>'. `hint` is
    an optional substring we expect inside; if given and no match found, raises."""
    start = xml.find(open_tag)
    if start == -1:
        raise RuntimeError(f"could not find opening tag {open_tag!r}")
    end = xml.find(close_tag, start)
    if end == -1:
        raise RuntimeError(f"could not find closing tag {close_tag!r}")
    end += len(close_tag)
    body = xml[start:end]
    if hint is not None and hint not in body:
        raise RuntimeError(f"block {open_tag} found but does not contain hint {hint!r}")
    return start, end


def _scoped_sub(xml, outer_start, outer_end, pattern, replacement, count=0):
    """Apply a regex substitution only within a byte range of the text. Returns
    (new_xml, new_outer_end, n_replacements)."""
    before, middle, after = xml[:outer_start], xml[outer_start:outer_end], xml[outer_end:]
    new_middle, n = re.subn(pattern, replacement, middle, count=count)
    return before + new_middle + after, outer_end + (len(new_middle) - len(middle)), n


def _ipv4_secondary_for(iface, topo):
    """Compute the secondary's real IP for an interface from topology rules."""
    primary_ip = iface["primary_current_ip"]
    suffix = topo["secondary"]["real_ip_suffix"]
    prefix_part = primary_ip.rsplit(".", 1)[0]
    return f"{prefix_part}.{suffix}"


def _ipv4_primary_new_for(iface, topo):
    """Compute the primary's new real IP after renumber."""
    primary_ip = iface["primary_current_ip"]
    suffix = topo["primary"]["real_ip_suffix"]
    prefix_part = primary_ip.rsplit(".", 1)[0]
    return f"{prefix_part}.{suffix}"


def _ipv6_secondary_for(ipv6_block, topo):
    """Return the secondary's real IPv6 host address for an interface.
    Requires topology to EXPLICITLY specify `secondary_ip` in the ipv6 block —
    IPv6 is not auto-derived because decimal/hex ambiguity produces surprises."""
    return ipv6_block["secondary_ip"]


def _ipv6_carp_vip_for(ipv6_block):
    """Return the CARP VIP IPv6 address. Explicit in the topology — the VIP is what
    clients use as their gateway, and must be a valid unicast host address
    (not the subnet-router anycast `::`)."""
    return ipv6_block["carp_vip"]


# ------------------------------------------------------------------
# Primary → secondary transform
# ------------------------------------------------------------------

def transform_secondary(primary_xml, topo):
    """
    Produce a full secondary config.xml from the primary's config.xml + topology.

    Changes applied:
      1. <system><hostname>: append "-sec"
      2. <interfaces><wan>: clear enable/ipaddr/subnet/gateway (deferred to CARP-at-WAN)
      3. <interfaces><lan|optN>: change primary_current_ip -> secondary IP (suffix from topology)
      4. Add <interfaces><opt_tag> for the sync link (from topology.sync_link)
      5. Under <dhcpd>, <dhcpdv6>: strip <enable>1</enable> everywhere (secondary must not serve DHCP)
      6. <unboundplus><general><enabled>1</enabled> -> 0
      7. <tailscale><settings><enabled>1</enabled> -> 0
      8. <sysctl>: add net.inet.carp.preempt=1 if not present
      9. <interfaces> opt_tag added with secondary's sync_link IP
      10. <virtualip>: replace with CARP VIPs per topology (advskew=secondary_advskew, backup role)
      11. <hasync>: populate pfsyncinterface, pfsyncpeerip, synchronizetoip from topology
    """
    x = primary_xml
    audit = []

    # --- 1. Hostname ---
    sys_start, sys_end = _find_block(x, "<system>", "</system>", hint="<hostname>")
    x, sys_end, n = _scoped_sub(
        x, sys_start, sys_end,
        r"<hostname>([^<]+)</hostname>",
        r"<hostname>\1-sec</hostname>",
        count=1,
    )
    audit.append(("hostname: added '-sec' suffix", n))

    # --- 2. WAN disable (find wan iface that has defer_carp=true, usually always true in /30 case) ---
    wan_iface = next((i for i in topo["interfaces"] if i["iface_tag"] == "wan"), None)

    # Locate the real <interfaces> block (not a string match elsewhere). It starts at depth 1.
    if_start = x.find("\n  <interfaces>\n")
    if if_start == -1:
        raise RuntimeError("could not find top-level <interfaces> block")
    if_end = x.find("\n  </interfaces>", if_start) + len("\n  </interfaces>")

    if wan_iface is not None:
        wan_re = re.compile(r"    <wan>\n(.*?)\n    </wan>", re.DOTALL)
        def _wan_repl(m):
            body = m.group(1)
            body = re.sub(r"\s*<enable>1</enable>\n", "\n", body, count=1)
            body = re.sub(r"<ipaddr>[^<]*</ipaddr>", "<ipaddr/>", body)
            body = re.sub(r"<subnet>[^<]*</subnet>", "<subnet/>", body)
            body = re.sub(r"<gateway>[^<]*</gateway>", "<gateway/>", body)
            return f"    <wan>\n{body}\n    </wan>"
        section = x[if_start:if_end]
        new_section, n = wan_re.subn(_wan_repl, section, count=1)
        x = x[:if_start] + new_section + x[if_end:]
        if_end = if_start + len(new_section)
        audit.append(("WAN interface: disabled and IPs blanked", n))

    # --- 3. Renumber LAN + OPT* interfaces ---
    total_renumber = 0
    for iface in topo["interfaces"]:
        if iface["iface_tag"] == "wan":
            continue
        tag = iface["iface_tag"]
        old_v4 = iface["primary_current_ip"]
        new_v4 = _ipv4_secondary_for(iface, topo)

        # Scoped substitution inside <tagname>...</tagname>
        iface_re = re.compile(rf"    <{tag}>\n(.*?)\n    </{tag}>", re.DOTALL)
        section = x[if_start:if_end]

        def _iface_repl(m, tag=tag, old_v4=old_v4, new_v4=new_v4, ipv6=iface.get("ipv6")):
            body = m.group(1)
            body = body.replace(f"<ipaddr>{old_v4}</ipaddr>", f"<ipaddr>{new_v4}</ipaddr>")
            if ipv6:
                old_v6 = ipv6["primary_current_ip"]
                new_v6 = _ipv6_secondary_for(ipv6, topo)
                body = body.replace(
                    f"<ipaddrv6>{old_v6}</ipaddrv6>",
                    f"<ipaddrv6>{new_v6}</ipaddrv6>",
                )
            return f"    <{tag}>\n{body}\n    </{tag}>"

        new_section, n = iface_re.subn(_iface_repl, section, count=1)
        if n == 0:
            # Interface tag not found — topology lists an iface that isn't in the primary's config
            audit.append((f"interface <{tag}>: NOT FOUND in primary config — skipped", 0))
            continue
        x = x[:if_start] + new_section + x[if_end:]
        if_end = if_start + len(new_section)
        total_renumber += 1
    audit.append((f"LAN + OPT interfaces renumbered to secondary IPs", total_renumber))

    # --- 4. Add opt_tag (sync link) into <interfaces> ---
    sync = topo["sync_link"]
    sync_tag = sync["opt_tag"]
    sync_entry = (
        f"    <{sync_tag}>\n"
        f"      <if>{sync['guest_if']}</if>\n"
        f"      <descr>{sync.get('descr', 'HA-SYNC')}</descr>\n"
        f"      <enable>1</enable>\n"
        f"      <spoofmac/>\n"
        f"      <ipaddr>{sync['secondary_ip']}</ipaddr>\n"
        f"      <subnet>{sync['prefix']}</subnet>\n"
        f"    </{sync_tag}>\n"
    )
    # Only add if not already present
    if f"<{sync_tag}>" not in x:
        close_idx = x.find("\n  </interfaces>")
        x = x[:close_idx] + "\n" + sync_entry.rstrip() + x[close_idx:]
        audit.append((f"sync interface <{sync_tag}> added ({sync['secondary_ip']}/{sync['prefix']})", 1))
    else:
        audit.append((f"sync interface <{sync_tag}> already present — skipped", 0))

    # --- 5. DHCP disable ---
    if "dhcpd" in topo.get("disable_on_secondary", []):
        d_start = x.find("\n  <dhcpd>\n")
        if d_start != -1:
            d_end = x.find("\n  </dhcpd>", d_start) + len("\n  </dhcpd>")
            x, d_end, n = _scoped_sub(
                x, d_start, d_end,
                r"\n      <enable>1</enable>",
                r"",
            )
            audit.append((f"dhcpd: <enable> removed from {n} interfaces", n))

    if "dhcpdv6" in topo.get("disable_on_secondary", []):
        d6_start = x.find("\n  <dhcpdv6>\n")
        if d6_start != -1:
            d6_end = x.find("\n  </dhcpdv6>", d6_start) + len("\n  </dhcpdv6>")
            x, d6_end, n = _scoped_sub(
                x, d6_start, d6_end,
                r"\n      <enable>1</enable>",
                r"",
            )
            audit.append((f"dhcpdv6: <enable> removed from {n} interfaces", n))

    # --- 6. Unbound disable ---
    if "unboundplus" in topo.get("disable_on_secondary", []):
        u_open = x.find("<unboundplus")
        if u_open != -1:
            u_close = x.find("</unboundplus>", u_open) + len("</unboundplus>")
            # Scope to <general>
            g_open = x.find("<general>", u_open, u_close)
            if g_open != -1:
                g_close = x.find("</general>", g_open) + len("</general>")
                x, g_close, n = _scoped_sub(
                    x, g_open, g_close,
                    r"<enabled>1</enabled>",
                    r"<enabled>0</enabled>",
                    count=1,
                )
                audit.append(("unboundplus DNS resolver disabled", n))

    # --- 7. Tailscale disable ---
    if "tailscale" in topo.get("disable_on_secondary", []):
        ts_open = x.find("<tailscale>")
        if ts_open != -1:
            ts_close = x.find("</tailscale>", ts_open) + len("</tailscale>")
            s_open = x.find("<settings", ts_open, ts_close)
            if s_open != -1:
                s_close = x.find("</settings>", s_open) + len("</settings>")
                x, s_close, n = _scoped_sub(
                    x, s_open, s_close,
                    r"<enabled>1</enabled>",
                    r"<enabled>0</enabled>",
                    count=1,
                )
                audit.append(("tailscale disabled on secondary", n))

    # --- 8. sysctl tunables (carp.preempt) ---
    if topo.get("carp", {}).get("preempt") and "net.inet.carp.preempt" not in x:
        sysctl_close = x.find("</sysctl>")
        if sysctl_close != -1:
            new_item = (
                f'    <item uuid="{uuid.uuid4()}">\n'
                f"      <tunable>net.inet.carp.preempt</tunable>\n"
                f"      <value>1</value>\n"
                f"      <descr>CARP preemption: backup takes over immediately when primary returns.</descr>\n"
                f"    </item>\n  "
            )
            x = x[:sysctl_close] + new_item + x[sysctl_close:]
            audit.append(("sysctl: net.inet.carp.preempt=1 added", 1))

    # --- 10. Virtual IPs (CARP) — replace the whole block ---
    vip_entries = []
    for iface in topo["interfaces"]:
        if iface.get("defer_carp") or iface["iface_tag"] == "wan":
            continue
        u = str(uuid.uuid4())
        vip_entries.append(f"""    <vip uuid="{u}">
      <mode>carp</mode>
      <interface>{_xe(iface['iface_tag'])}</interface>
      <descr>{_xe(iface.get('descr', iface['iface_tag']))} CARP</descr>
      <type>single</type>
      <subnet_bits>{iface['prefix']}</subnet_bits>
      <subnet>{_xe(iface['primary_current_ip'])}</subnet>
      <noexpand>0</noexpand>
      <vhid>{iface['vhid']}</vhid>
      <advskew>{topo['carp']['secondary_advskew']}</advskew>
      <advbase>{topo['carp'].get('advbase', 1)}</advbase>
      <password>{_xe(topo['carp']['password'])}</password>
    </vip>""")

        if iface.get("ipv6"):
            u6 = str(uuid.uuid4())
            v6 = iface["ipv6"]
            vip_entries.append(f"""    <vip uuid="{u6}">
      <mode>carp</mode>
      <interface>{_xe(iface['iface_tag'])}</interface>
      <descr>{_xe(iface.get('descr', iface['iface_tag']))} CARP IPv6</descr>
      <type>single</type>
      <subnet_bits>{v6['prefix']}</subnet_bits>
      <subnet>{_xe(_ipv6_carp_vip_for(v6))}</subnet>
      <noexpand>0</noexpand>
      <vhid>{v6['vhid']}</vhid>
      <advskew>{topo['carp']['secondary_advskew']}</advskew>
      <advbase>{topo['carp'].get('advbase', 1)}</advbase>
      <password>{_xe(topo['carp']['password'])}</password>
    </vip>""")

    new_vip_block = '<virtualip version="1.0.1">\n' + "\n".join(vip_entries) + "\n  </virtualip>"
    # Replace either '<virtualip...><vip/></virtualip>' OR '<virtualip...>...existing vips...</virtualip>'
    vip_re = re.compile(r"<virtualip[^/>]*>.*?</virtualip>", re.DOTALL)
    x, n = vip_re.subn(new_vip_block, x, count=1)
    if n == 0:
        raise RuntimeError("could not locate <virtualip> block to replace")
    audit.append((f"virtualip: {len(vip_entries)} CARP VIPs pre-seeded (advskew={topo['carp']['secondary_advskew']})", 1))

    # --- 11. hasync populate ---
    sync = topo["sync_link"]
    new_hasync = f"""<hasync version="1.0.2">
    <disablepreempt>0</disablepreempt>
    <disconnectppps>0</disconnectppps>
    <pfsyncinterface>{sync['opt_tag']}</pfsyncinterface>
    <pfsyncpeerip>{sync['primary_ip']}</pfsyncpeerip>
    <pfsyncversion>1400</pfsyncversion>
    <synchronizetoip>{sync['primary_ip']}</synchronizetoip>
    <verifypeer>0</verifypeer>
    <username>root</username>
    <password/>
    <syncitems/>
  </hasync>"""
    hasync_re = re.compile(r"<hasync[^>]*>.*?</hasync>", re.DOTALL)
    x, n = hasync_re.subn(new_hasync, x, count=1)
    if n == 0:
        raise RuntimeError("could not locate <hasync> block")
    audit.append((f"hasync: pfsync iface={sync['opt_tag']}, peer={sync['primary_ip']}, xmlrpc={sync['primary_ip']}", 1))

    return x, audit


# ------------------------------------------------------------------
# Primary inject CARP — add CARP VIPs to primary without renumbering it yet
# ------------------------------------------------------------------

def inject_primary_carp(primary_xml, topo):
    """
    Add CARP VIPs to primary config while keeping primary's real IP at .1.

    This is non-disruptive — OPNsense allows <ipaddr>.1</ipaddr> on the interface
    AND a CARP VIP at .1 simultaneously (the CARP VIP is an alias-style second
    address). After this step, the primary still answers as .1 via its real IP;
    CARP elections just start happening. Clients see no change.

    Also adds the sync interface (opt_tag) and the hasync block pointing at
    the secondary, and the CARP preempt tunable.
    """
    x = primary_xml
    audit = []

    # --- Add opt_tag sync interface with primary_ip ---
    sync = topo["sync_link"]
    sync_tag = sync["opt_tag"]
    if f"<{sync_tag}>" not in x:
        sync_entry = (
            f"    <{sync_tag}>\n"
            f"      <if>{sync['guest_if']}</if>\n"
            f"      <descr>{sync.get('descr', 'HA-SYNC')}</descr>\n"
            f"      <enable>1</enable>\n"
            f"      <spoofmac/>\n"
            f"      <ipaddr>{sync['primary_ip']}</ipaddr>\n"
            f"      <subnet>{sync['prefix']}</subnet>\n"
            f"    </{sync_tag}>\n"
        )
        close_idx = x.find("\n  </interfaces>")
        x = x[:close_idx] + "\n" + sync_entry.rstrip() + x[close_idx:]
        audit.append((f"sync interface <{sync_tag}> added on primary ({sync['primary_ip']}/{sync['prefix']})", 1))

    # --- sysctl net.inet.carp.preempt ---
    if topo["carp"].get("preempt") and "net.inet.carp.preempt" not in x:
        sysctl_close = x.find("</sysctl>")
        if sysctl_close != -1:
            new_item = (
                f'    <item uuid="{uuid.uuid4()}">\n'
                f"      <tunable>net.inet.carp.preempt</tunable>\n"
                f"      <value>1</value>\n"
                f"      <descr>CARP preemption.</descr>\n"
                f"    </item>\n  "
            )
            x = x[:sysctl_close] + new_item + x[sysctl_close:]
            audit.append(("sysctl: net.inet.carp.preempt=1", 1))

    # --- CARP VIPs (advskew=primary_advskew, role=master) ---
    vip_entries = []
    for iface in topo["interfaces"]:
        if iface.get("defer_carp") or iface["iface_tag"] == "wan":
            continue
        u = str(uuid.uuid4())
        vip_entries.append(f"""    <vip uuid="{u}">
      <mode>carp</mode>
      <interface>{_xe(iface['iface_tag'])}</interface>
      <descr>{_xe(iface.get('descr', iface['iface_tag']))} CARP</descr>
      <type>single</type>
      <subnet_bits>{iface['prefix']}</subnet_bits>
      <subnet>{_xe(iface['primary_current_ip'])}</subnet>
      <noexpand>0</noexpand>
      <vhid>{iface['vhid']}</vhid>
      <advskew>{topo['carp']['primary_advskew']}</advskew>
      <advbase>{topo['carp'].get('advbase', 1)}</advbase>
      <password>{_xe(topo['carp']['password'])}</password>
    </vip>""")
        if iface.get("ipv6"):
            u6 = str(uuid.uuid4())
            v6 = iface["ipv6"]
            vip_entries.append(f"""    <vip uuid="{u6}">
      <mode>carp</mode>
      <interface>{_xe(iface['iface_tag'])}</interface>
      <descr>{_xe(iface.get('descr', iface['iface_tag']))} CARP IPv6</descr>
      <type>single</type>
      <subnet_bits>{v6['prefix']}</subnet_bits>
      <subnet>{_xe(_ipv6_carp_vip_for(v6))}</subnet>
      <noexpand>0</noexpand>
      <vhid>{v6['vhid']}</vhid>
      <advskew>{topo['carp']['primary_advskew']}</advskew>
      <advbase>{topo['carp'].get('advbase', 1)}</advbase>
      <password>{_xe(topo['carp']['password'])}</password>
    </vip>""")

    new_vip_block = '<virtualip version="1.0.1">\n' + "\n".join(vip_entries) + "\n  </virtualip>"
    vip_re = re.compile(r"<virtualip[^/>]*>.*?</virtualip>", re.DOTALL)
    x, n = vip_re.subn(new_vip_block, x, count=1)
    if n == 0:
        raise RuntimeError("could not locate <virtualip> block to replace")
    audit.append((f"primary virtualip: {len(vip_entries)} CARP VIPs added (advskew={topo['carp']['primary_advskew']}, master role)", 1))

    # --- hasync populate (peer = secondary_ip) ---
    new_hasync = f"""<hasync version="1.0.2">
    <disablepreempt>0</disablepreempt>
    <disconnectppps>0</disconnectppps>
    <pfsyncinterface>{sync['opt_tag']}</pfsyncinterface>
    <pfsyncpeerip>{sync['secondary_ip']}</pfsyncpeerip>
    <pfsyncversion>1400</pfsyncversion>
    <synchronizetoip>{sync['secondary_ip']}</synchronizetoip>
    <verifypeer>0</verifypeer>
    <username>root</username>
    <password/>
    <syncitems/>
  </hasync>"""
    hasync_re = re.compile(r"<hasync[^>]*>.*?</hasync>", re.DOTALL)
    x, n = hasync_re.subn(new_hasync, x, count=1)
    if n == 0:
        raise RuntimeError("could not locate <hasync> block")
    audit.append((f"hasync on primary: pfsync iface={sync['opt_tag']}, peer={sync['secondary_ip']}", 1))

    return x, audit


# ------------------------------------------------------------------
# Activate — renumber primary's real IPs from .1 to primary_real_ip_suffix
# ------------------------------------------------------------------

def activate_primary_renumber(primary_xml_with_carp, topo):
    """
    Renumber primary's LAN/OPT real IPs from their current .1 form to the
    primary_real_ip_suffix form (e.g. .251). Leaves CARP VIPs (already at .1) alone.

    This is the disruptive step — causes a ~5s ARP reconverge per interface as
    CARP takes over the .1 answers. DO NOT use this without a maintenance window.
    """
    x = primary_xml_with_carp
    audit = []

    if_start = x.find("\n  <interfaces>\n")
    if_end = x.find("\n  </interfaces>", if_start) + len("\n  </interfaces>")

    # Pre-flight: warn about interfaces with IPv6 but no primary_new_ip defined
    v6_missing = [i["iface_tag"] for i in topo["interfaces"]
                  if i.get("ipv6") and "primary_new_ip" not in i["ipv6"]]
    if v6_missing:
        audit.append((f"INFO: IPv6 primary_new_ip missing for {', '.join(v6_missing)} "
                     f"— primary's IPv6 address will stay unchanged on those interfaces", 0))

    total = 0
    skipped = []
    for iface in topo["interfaces"]:
        if iface["iface_tag"] == "wan":
            continue
        tag = iface["iface_tag"]
        old_v4 = iface["primary_current_ip"]
        new_v4 = _ipv4_primary_new_for(iface, topo)

        iface_re = re.compile(rf"    <{tag}>\n(.*?)\n    </{tag}>", re.DOTALL)
        section = x[if_start:if_end]

        def _iface_repl(m, tag=tag, old_v4=old_v4, new_v4=new_v4, ipv6=iface.get("ipv6")):
            body = m.group(1)
            body = body.replace(f"<ipaddr>{old_v4}</ipaddr>", f"<ipaddr>{new_v4}</ipaddr>")
            if ipv6:
                old_v6 = ipv6["primary_current_ip"]
                # Primary's new IPv6 must be explicit in the topology — we don't auto-derive.
                # If not specified, keep the old value. Topology schema should include a
                # `primary_new_ip` field in the ipv6 block for full activation.
                new_v6 = ipv6.get("primary_new_ip", old_v6)
                body = body.replace(f"<ipaddrv6>{old_v6}</ipaddrv6>", f"<ipaddrv6>{new_v6}</ipaddrv6>")
            return f"    <{tag}>\n{body}\n    </{tag}>"

        new_section, n = iface_re.subn(_iface_repl, section, count=1)
        if n:
            x = x[:if_start] + new_section + x[if_end:]
            if_end = if_start + len(new_section)
            total += 1
        else:
            skipped.append(tag)
    audit.append((f"primary interfaces renumbered to .{topo['primary']['real_ip_suffix']}", total))
    if skipped:
        audit.append((f"WARNING: could not find these interfaces in config (renumber skipped): {', '.join(skipped)}", 0))
    return x, audit


# =============================================================================
# CLI subcommands
# =============================================================================

def cmd_init_topology(args):
    out = Path(args.path)
    if out.exists() and not args.force:
        print(f"ERROR: {out} exists. Re-run with --force to overwrite.", file=sys.stderr)
        return 2
    out.write_text(json.dumps(EXAMPLE_TOPOLOGY, indent=2) + "\n")
    print(f"wrote example topology: {out}")
    print("Edit it (especially primary.vmid, secondary.vmid, interfaces[].primary_current_ip, carp.password),")
    print("then run:  opnsense-ha-config.py validate --topology " + str(out))
    return 0


def cmd_validate(args):
    topo = load_topology(args.topology)
    print(f"topology OK: {len(topo['interfaces'])} interfaces, "
          f"primary VMID {topo['primary']['vmid']}, "
          f"secondary VMID {topo['secondary']['vmid']}, "
          f"sync link {topo['sync_link']['primary_ip']} <-> {topo['sync_link']['secondary_ip']}")
    return 0


def cmd_transform_secondary(args):
    topo = load_topology(args.topology)
    primary_xml = _read_xml(args.primary_config)
    secondary_xml, audit = transform_secondary(primary_xml, topo)
    # Validate XML output parses
    _check_xml(secondary_xml)
    Path(args.output).write_text(secondary_xml)
    print(f"wrote secondary config: {args.output} ({len(secondary_xml)} bytes)")
    print("changes:")
    for msg, n in audit:
        print(f"  [{n:>3}] {msg}")
    return 0


def cmd_inject_primary_carp(args):
    topo = load_topology(args.topology)
    primary_xml = _read_xml(args.primary_config)
    new_xml, audit = inject_primary_carp(primary_xml, topo)
    _check_xml(new_xml)
    Path(args.output).write_text(new_xml)
    print(f"wrote primary-with-CARP config: {args.output} ({len(new_xml)} bytes)")
    print("NOTE: This is NON-DISRUPTIVE. Primary still owns .1 as its real IP.")
    print("      CARP VIPs become active as MASTER, but clients see no change until")
    print("      the activate-primary-renumber step is applied later.")
    print("changes:")
    for msg, n in audit:
        print(f"  [{n:>3}] {msg}")
    return 0


def cmd_activate_primary_renumber(args):
    topo = load_topology(args.topology)
    primary_xml = _read_xml(args.primary_config)
    new_xml, audit = activate_primary_renumber(primary_xml, topo)
    _check_xml(new_xml)
    Path(args.output).write_text(new_xml)
    print(f"wrote primary-activated config: {args.output} ({len(new_xml)} bytes)")
    print("WARNING: This config renumbers primary's real IPs. Deploying it will")
    print("         cause a brief (~5s per interface) ARP reconverge as CARP VIPs")
    print("         take over the .1 addresses. Deploy ONLY during a maintenance window.")
    print("changes:")
    for msg, n in audit:
        print(f"  [{n:>3}] {msg}")
    return 0


def cmd_diff(args):
    """Very coarse textual diff between two config.xml files."""
    try:
        a = Path(args.file_a).read_text().splitlines()
        b = Path(args.file_b).read_text().splitlines()
    except FileNotFoundError as e:
        raise RuntimeError(f"file not found: {e.filename}")
    except PermissionError as e:
        raise RuntimeError(f"permission denied: {e.filename}")
    import difflib
    diff = difflib.unified_diff(a, b, fromfile=args.file_a, tofile=args.file_b, lineterm="")
    for line in diff:
        print(line)
    return 0


def _check_xml(text):
    import xml.etree.ElementTree as ET
    try:
        ET.fromstring(text)
    except ET.ParseError as e:
        print(f"ERROR: generated config.xml is not valid XML: {e}", file=sys.stderr)
        sys.exit(3)


# =============================================================================
# Main
# =============================================================================

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="OPNsense CARP HA config transformer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sp = parser.add_subparsers(dest="cmd", required=True)

    p_init = sp.add_parser("init-topology", help="write an example topology.json")
    p_init.add_argument("path")
    p_init.add_argument("--force", action="store_true")
    p_init.set_defaults(func=cmd_init_topology)

    p_val = sp.add_parser("validate", help="validate a topology.json")
    p_val.add_argument("--topology", required=True)
    p_val.set_defaults(func=cmd_validate)

    p_ts = sp.add_parser("transform-secondary", help="primary config.xml -> secondary config.xml")
    p_ts.add_argument("--primary-config", required=True)
    p_ts.add_argument("--output", required=True)
    p_ts.add_argument("--topology", required=True)
    p_ts.set_defaults(func=cmd_transform_secondary)

    p_ip = sp.add_parser("inject-primary-carp",
                         help="add CARP VIPs + sync iface + hasync to primary config.xml (non-disruptive)")
    p_ip.add_argument("--primary-config", required=True)
    p_ip.add_argument("--output", required=True)
    p_ip.add_argument("--topology", required=True)
    p_ip.set_defaults(func=cmd_inject_primary_carp)

    p_ac = sp.add_parser("activate-primary-renumber",
                         help="renumber primary .1 -> primary suffix (DISRUPTIVE deploy)")
    p_ac.add_argument("--primary-config", required=True)
    p_ac.add_argument("--output", required=True)
    p_ac.add_argument("--topology", required=True)
    p_ac.set_defaults(func=cmd_activate_primary_renumber)

    p_df = sp.add_parser("diff", help="unified textual diff of two config files")
    p_df.add_argument("file_a")
    p_df.add_argument("file_b")
    p_df.set_defaults(func=cmd_diff)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, RuntimeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
