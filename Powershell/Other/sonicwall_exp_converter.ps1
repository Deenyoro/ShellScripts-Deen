<#
.SYNOPSIS
    Convert a SonicWall .exp backup (base64 of URL-encoded key=value pairs)
    into a human-readable migration-oriented summary.

.DESCRIPTION
    Captures zones, interfaces, DNS, address / service objects and groups,
    DHCP scopes and static leases, DHCP options, NAT, firewall rules,
    routing, IPsec + SSL VPN, and schedules. System defaults are filtered
    out so the output is what a tech would re-enter on a replacement unit.

.EXAMPLE
    .\sonicwall_exp_converter.ps1 -InputFile .\sonicwall.exp -OutputFile .\config.txt
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$InputFile,

    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputFile) {
    $OutputFile = [IO.Path]::ChangeExtension($InputFile, 'txt')
}

# --- Decode ----------------------------------------------------------------
Write-Host "Reading $InputFile..."
$raw = (Get-Content -LiteralPath $InputFile -Raw).Trim().TrimEnd('&')
try {
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
} catch {
    throw "File does not look like a base64-encoded SonicWall export: $($_.Exception.Message)"
}

$config = @{}
foreach ($pair in ($decoded -split '&')) {
    $pairDec = [uri]::UnescapeDataString($pair)
    if ($pairDec -match '^(?<k>[^=]+)=(?<v>.*)$') {
        $config[$Matches.k] = $Matches.v
    }
}
Write-Host "Parsed $($config.Count) parameters."

# --- Output (StringBuilder = O(n) vs $array+= at O(n^2)) -------------------
$sb = New-Object System.Text.StringBuilder

function Add-Line { param([string]$Text='') [void]$sb.AppendLine($Text) }
function Add-Section {
    param([Parameter(Mandatory)][string]$Title)
    Add-Line ''
    Add-Line ('=' * 80)
    Add-Line $Title
    Add-Line ('=' * 80)
}

function Get-IndexedKey {
    param([Parameter(Mandatory)][string]$Pattern)
    # Returns the numeric suffixes from keys matching Pattern (which must contain `(\d+)`).
    $config.Keys |
        Where-Object { $_ -match $Pattern } |
        ForEach-Object { [int]($_ -replace '\D','') } |
        Sort-Object -Unique
}

function Get-Val {
    param([Parameter(Mandatory)][string]$Key)
    if ($config.ContainsKey($Key)) { return $config[$Key] }
    return $null
}

# --- Header ----------------------------------------------------------------
Add-Line ('=' * 80)
Add-Line 'SONICWALL CONFIGURATION EXPORT - ESSENTIAL FOR MIGRATION'
Add-Line "Firmware: $(Get-Val 'buildNum')"
Add-Line "Device:   $(Get-Val 'shortProdName')"
Add-Line ('=' * 80)

# --- Zones -----------------------------------------------------------------
Add-Section 'ZONES'
foreach ($i in (Get-IndexedKey '^zoneObjId_\d+$')) {
    $name = Get-Val "zoneObjId_$i"
    $type = Get-Val "zoneObjZoneType_$i"
    $desc = switch ($type) {
        '0' {'Untrusted'} '1' {'Trusted'} '2' {'Public'}
        '3' {'Wireless'}  '4' {'Encrypted'} '5' {'SSLVPN'}
        default {"Type $type"}
    }
    Add-Line "Zone: $name ($desc)"
}

# --- Interfaces ------------------------------------------------------------
Add-Section 'INTERFACES'
$ifaceIds = Get-IndexedKey '^iface_name_\d+$'
foreach ($i in $ifaceIds) {
    $name    = Get-Val "iface_name_$i"
    $comment = Get-Val "iface_comment_$i"
    $ip      = Get-Val "iface_static_ip_$i"
    $mask    = Get-Val "iface_static_mask_$i"
    $gw      = Get-Val "iface_static_gateway_$i"
    $zone    = Get-Val "iface_zone_$i"
    $mode    = Get-Val "iface_mode_$i"
    $vlan    = Get-Val "iface_vlanId_$i"
    $mtu     = Get-Val "iface_mtu_$i"
    $modeDesc = switch ($mode) {
        '0' {'Static'} '1' {'DHCP'} '2' {'PPPoE'}
        '3' {'PPTP'}   '4' {'L2TP'}
        default {"Mode $mode"}
    }

    if (-not ($name -or $ip -or $comment)) { continue }
    Add-Line "Interface ${i}: $name"
    if ($comment)                         { Add-Line "  Description: $comment" }
    if ($zone)                            { Add-Line "  Zone: $zone" }
    if ($mode)                            { Add-Line "  Mode: $modeDesc" }
    if ($ip   -and $ip   -ne '0.0.0.0')   { Add-Line "  IP Address: $ip" }
    if ($mask -and $mask -ne '0.0.0.0')   { Add-Line "  Subnet Mask: $mask" }
    if ($gw   -and $gw   -ne '0.0.0.0')   { Add-Line "  Gateway: $gw" }
    if ($vlan -and $vlan -ne '0')         { Add-Line "  VLAN ID: $vlan" }
    if ($mtu  -and $mtu -notin '1500','0'){ Add-Line "  MTU: $mtu" }
    Add-Line
}

# --- DNS -------------------------------------------------------------------
Add-Section 'DNS SETTINGS'
Add-Line "DNS Server 1: $(Get-Val 'dns_server_one')"
Add-Line "DNS Server 2: $(Get-Val 'dns_server_two')"
Add-Line "DNS Server 3: $(Get-Val 'dns_server_three')"
if ((Get-Val 'dnsProxy_enable')      -eq 'on') { Add-Line 'DNS Proxy: Enabled' }
if ((Get-Val 'dnsProxySplit_enable') -eq 'on') { Add-Line 'Split DNS: Enabled' }

# --- Address objects -------------------------------------------------------
Add-Section 'ADDRESS OBJECTS (Custom)'
$systemRx = '^(Default|Firewalled|.*Subnets$|.*Interface IP$|All .*|.*Primary.*|U\d+ |.*Enforcement.*|RBL.*|Public Mail.*|Node License.*|Dial-Up.*|SonicPoints|X\d+ (IP|Subnet|Default))'
foreach ($i in (Get-IndexedKey '^addrObjId_\d+$')) {
    $name = Get-Val "addrObjId_$i"
    $type = Get-Val "addrObjType_$i"
    $zone = Get-Val "addrObjZone_$i"
    $ip1  = Get-Val "addrObjIp1_$i"
    $ip2  = Get-Val "addrObjIp2_$i"
    $fqdn = Get-Val "addrObjFqdn_$i"
    $typeDesc = switch ($type) {
        '1' {'Host'} '2' {'Range'} '4' {'Network'} '8' {'MAC'} '16' {'FQDN'}
        default {"Type $type"}
    }
    if (-not $name) { continue }
    if ($name -match $systemRx) { continue }
    $hasData = ($ip1 -and $ip1 -ne '0.0.0.0') -or $fqdn
    if (-not $hasData) { continue }

    Add-Line "Name: $name"
    Add-Line "  Type: $typeDesc"
    if ($zone)                                              { Add-Line "  Zone: $zone" }
    if ($ip1 -and $ip1 -ne '0.0.0.0')                       { Add-Line "  IP/Start: $ip1" }
    if ($ip2 -and $ip2 -ne '0.0.0.0' -and $ip2 -ne $ip1 -and $ip2 -ne '255.255.255.255') {
        Add-Line "  End/Mask: $ip2"
    }
    if ($fqdn)                                              { Add-Line "  FQDN: $fqdn" }
    Add-Line
}

# --- Address groups --------------------------------------------------------
Add-Section 'ADDRESS GROUPS'
$addrGrpMembers = @{}
foreach ($i in (Get-IndexedKey '^ao_atomToGrp_\d+$')) {
    $member = Get-Val "ao_atomToGrp_$i"
    $group  = Get-Val "ao_grpToGrp_$i"
    if (-not ($group -and $member)) { continue }
    if (-not $addrGrpMembers.ContainsKey($group)) { $addrGrpMembers[$group] = [Collections.Generic.List[string]]::new() }
    if (-not $addrGrpMembers[$group].Contains($member)) { $addrGrpMembers[$group].Add($member) | Out-Null }
}

$customGrpCount = 0
foreach ($i in (Get-IndexedKey '^addrObjGrpId_\d+$')) {
    $name = Get-Val "addrObjGrpId_$i"
    if ($name -and $name -notmatch '^(All |Default|Firewalled)') {
        $customGrpCount++
        Add-Line "Group: $name"
    }
}
foreach ($grp in ($addrGrpMembers.Keys | Sort-Object)) {
    if ($grp -match '^(All |Default|Firewalled)') { continue }
    Add-Line ''
    Add-Line "Group: $grp"
    foreach ($m in $addrGrpMembers[$grp]) { Add-Line "  - $m" }
}
if ($customGrpCount -eq 0 -and $addrGrpMembers.Count -eq 0) {
    Add-Line 'No custom address groups configured.'
}

# --- Service objects -------------------------------------------------------
Add-Section 'SERVICE OBJECTS (Custom)'
$customSvcCount = 0
foreach ($i in (Get-IndexedKey '^svcObjId_\d+$')) {
    $name  = Get-Val "svcObjId_$i"
    $proto = Get-Val "svcObjIpType_$i"
    $p1    = Get-Val "svcObjPort1_$i"
    $p2    = Get-Val "svcObjPort2_$i"
    $desc  = switch ($proto) { '6' {'TCP'} '17' {'UDP'} '1' {'ICMP'} '47' {'GRE'} '50' {'ESP'} default {"Proto $proto"} }
    $isCustom = ($name -match '^\d+\.\d+\.\d+\.\d+') -or ($name -match '^(Camera|Security|Agam|DVR).*Services')
    if (-not ($name -and $isCustom)) { continue }

    $customSvcCount++
    Add-Line "Service: $name"
    Add-Line "  Protocol: $desc"
    if ($p1)                { Add-Line "  Port Start: $p1" }
    if ($p2 -and $p2 -ne $p1) { Add-Line "  Port End: $p2" }
    Add-Line
}
if ($customSvcCount -eq 0) { Add-Line 'No custom service objects configured.' }

# --- Service groups --------------------------------------------------------
Add-Section 'SERVICE GROUPS (Custom)'
$svcGrpMembers = @{}
foreach ($i in (Get-IndexedKey '^so_atomToGrp_\d+$')) {
    $member = Get-Val "so_atomToGrp_$i"
    $group  = Get-Val "so_grpToGrp_$i"
    if (-not ($group -and $member)) { continue }
    if ($group -notmatch '^\d+\.\d+|Camera|Security|Agam|DVR') { continue }
    if (-not $svcGrpMembers.ContainsKey($group)) { $svcGrpMembers[$group] = [Collections.Generic.List[string]]::new() }
    if (-not $svcGrpMembers[$group].Contains($member)) { $svcGrpMembers[$group].Add($member) | Out-Null }
}
if ($svcGrpMembers.Count -gt 0) {
    foreach ($g in ($svcGrpMembers.Keys | Sort-Object)) {
        Add-Line "Group: $g"
        foreach ($m in $svcGrpMembers[$g]) { Add-Line "  - $m" }
        Add-Line
    }
} else {
    Add-Line 'No custom service groups configured.'
}

# --- DHCP scopes -----------------------------------------------------------
Add-Section 'DHCP CONFIGURATION'
Add-Line 'Global Settings:'
Add-Line "  Domain: $(Get-Val 'dhcp_domainname')"
Add-Line "  Default Lease: $(Get-Val 'dhcp_lease') minutes"
Add-Line "  DNS1: $(Get-Val 'dhcp_dns0')"
Add-Line "  DNS2: $(Get-Val 'dhcp_dns1')"
Add-Line

$dhcpScopes = @{}
foreach ($k in ($config.Keys | Where-Object { $_ -match '^prefs_dhdyn(?<prop>\w+?)_(?<n>\d+)$' })) {
    [void]($k -match '^prefs_dhdyn(?<prop>\w+?)_(?<n>\d+)$')
    if (-not $dhcpScopes.ContainsKey($Matches.n)) { $dhcpScopes[$Matches.n] = @{} }
    $dhcpScopes[$Matches.n][$Matches.prop] = $config[$k]
}
foreach ($n in ($dhcpScopes.Keys | Sort-Object { [int]$_ })) {
    $s = $dhcpScopes[$n]
    Add-Line "DHCP Scope ${n}:"
    if ($s.ContainsKey('scopeactive')) {
        $en = if ($s['scopeactive'] -eq 'on') {'Yes'} else {'No'}
        Add-Line "  Enabled: $en"
    }
    foreach ($pair in @(
        @('start',       'Range Start'),
        @('end',         'Range End'),
        @('subnetmask',  'Subnet Mask'),
        @('router',      'Gateway'),
        @('dns0',        'DNS1'),
        @('dns1',        'DNS2'),
        @('domainname',  'Domain'),
        @('lease',       'Lease (min)'),
        @('DhcpOptGrp',  'DHCP Option Group')
    )) {
        if ($s.ContainsKey($pair[0]) -and $s[$pair[0]]) { Add-Line "  $($pair[1]): $($s[$pair[0]])" }
    }
    Add-Line
}

# --- Static DHCP leases ----------------------------------------------------
Add-Section 'STATIC DHCP LEASES'
$staticLeases = @{}
foreach ($k in ($config.Keys | Where-Object { $_ -match '^prefs_dhstatic(?<prop>\w+?)_(?<n>\d+)$' })) {
    [void]($k -match '^prefs_dhstatic(?<prop>\w+?)_(?<n>\d+)$')
    if (-not $staticLeases.ContainsKey($Matches.n)) { $staticLeases[$Matches.n] = @{} }
    $staticLeases[$Matches.n][$Matches.prop] = $config[$k]
}
$leaseCount = 0
foreach ($n in ($staticLeases.Keys | Sort-Object { [int]$_ })) {
    $s = $staticLeases[$n]
    if (-not ($s.ContainsKey('ip') -or $s.ContainsKey('hw'))) { continue }
    $leaseCount++
    Add-Line "Static Lease ${n}:"
    if ($s.ContainsKey('name')) { Add-Line "  Name: $($s['name'])" }
    if ($s.ContainsKey('ip'))   { Add-Line "  IP Address: $($s['ip'])" }
    if ($s.ContainsKey('hw')) {
        $mac = $s['hw']
        if ($mac.Length -eq 12) { $mac = ($mac -replace '(.{2})','$1:').TrimEnd(':') }
        Add-Line "  MAC Address: $mac"
    }
    if ($s.ContainsKey('router'))     { Add-Line "  Gateway: $($s['router'])" }
    if ($s.ContainsKey('subnetmask')) { Add-Line "  Subnet: $($s['subnetmask'])" }
    if ($s.ContainsKey('scopeactive') -and $s['scopeactive'] -eq 'on') { Add-Line '  Active: Yes' }
    Add-Line
}
if ($leaseCount -eq 0) { Add-Line 'No static DHCP leases configured.' }
Add-Line
Add-Line "Total Static Leases: $leaseCount"

# --- DHCP options ----------------------------------------------------------
Add-Section 'DHCP OPTIONS'
$optCount = 0
foreach ($i in (Get-IndexedKey '^dhcpOptionId_\d+$')) {
    $name   = Get-Val "dhcpOptionId_$i"
    $tagNum = Get-Val "dhcpOptionObjTagNumber_$i"
    $tagVal = Get-Val "dhcpOptionObjTagValue_$i"
    if (-not ($name -and $tagVal)) { continue }
    $optCount++
    Add-Line "Option: $name"
    Add-Line "  Tag Number: $tagNum"
    Add-Line "  Value: $tagVal"
    Add-Line
}
if ($optCount -eq 0) { Add-Line 'No custom DHCP options configured.' }

# --- NAT -------------------------------------------------------------------
Add-Section 'NAT POLICIES'
$nat = @{}
foreach ($k in ($config.Keys | Where-Object { $_ -match '^natPolicy(?<prop>\w+?)_(?<n>\d+)$' })) {
    [void]($k -match '^natPolicy(?<prop>\w+?)_(?<n>\d+)$')
    if (-not $nat.ContainsKey($Matches.n)) { $nat[$Matches.n] = @{} }
    $nat[$Matches.n][$Matches.prop] = $config[$k]
}
$natCount = 0
foreach ($n in ($nat.Keys | Sort-Object { [int]$_ })) {
    $p = $nat[$n]
    if (-not ($p.ContainsKey('OrigSrc') -or $p.ContainsKey('OrigDst') -or $p.ContainsKey('OrigSvc'))) { continue }
    $natCount++
    Add-Line "NAT Policy ${n}:"
    if ($p.ContainsKey('Name'))     { Add-Line "  Name: $($p['Name'])" }
    if ($p.ContainsKey('Enabled')) {
        $en = if ($p['Enabled'] -eq '1') {'Yes'} else {'No'}
        Add-Line "  Enabled: $en"
    }
    foreach ($pair in @(
        @('OrigSrc','Source Original'), @('TransSrc','Source Translated'),
        @('OrigDst','Dest Original'),   @('TransDst','Dest Translated'),
        @('OrigSvc','Service Original'),@('TransSvc','Service Translated'),
        @('Comment','Comment')
    )) {
        if ($p.ContainsKey($pair[0]) -and $p[$pair[0]]) { Add-Line "  $($pair[1]): $($p[$pair[0]])" }
    }
    Add-Line
}
Add-Line "Total NAT Policies: $natCount"

# --- Firewall rules --------------------------------------------------------
Add-Section 'FIREWALL ACCESS RULES'
$pol = @{}
foreach ($k in ($config.Keys | Where-Object { $_ -match '^policy(?<prop>\w+?)_(?<n>\d+)$' })) {
    [void]($k -match '^policy(?<prop>\w+?)_(?<n>\d+)$')
    if (-not $pol.ContainsKey($Matches.n)) { $pol[$Matches.n] = @{} }
    $pol[$Matches.n][$Matches.prop] = $config[$k]
}
$ruleCount = 0
foreach ($n in ($pol.Keys | Sort-Object { [int]$_ })) {
    $p = $pol[$n]
    $ruleCount++
    $actDesc = switch ($p['Action']) { '0' {'Deny'} '1' {'Discard'} '2' {'Allow'} default {"Action $($p['Action'])"} }
    Add-Line "Rule ${n}:"
    if ($p.ContainsKey('Name'))    { Add-Line "  Name: $($p['Name'])" }
    if ($p.ContainsKey('Enabled')) {
        $en = if ($p['Enabled'] -eq '1') {'Yes'} else {'No'}
        Add-Line "  Enabled: $en"
    }
    if ($p.ContainsKey('Action'))  { Add-Line "  Action: $actDesc" }
    foreach ($pair in @(
        @('SrcZone','Source Zone'), @('DstZone','Dest Zone'),
        @('SrcNet','Source'),       @('DstNet','Destination'),
        @('SrcSvc','Source Service'), @('DstSvc','Dest Service'),
        @('Time','Schedule'), @('Comment','Comment')
    )) {
        if ($p.ContainsKey($pair[0]) -and $p[$pair[0]]) { Add-Line "  $($pair[1]): $($p[$pair[0]])" }
    }
    if ($p['DefaultRule'] -eq '1') { Add-Line '  [DEFAULT RULE]' }
    if ($p['Management']  -eq '1') { Add-Line '  [MANAGEMENT RULE]' }
    Add-Line
}
Add-Line "Total Firewall Rules: $ruleCount"

# --- Static routes ---------------------------------------------------------
Add-Section 'ROUTING / STATIC ROUTES'
Add-Line '(Default routes are defined by interface gateways — see INTERFACES.)'
Add-Line
$routes = @{}
foreach ($k in ($config.Keys | Where-Object { $_ -match '^routePol(?<prop>\w+?)_(?<n>\d+)$' })) {
    [void]($k -match '^routePol(?<prop>\w+?)_(?<n>\d+)$')
    if (-not $routes.ContainsKey($Matches.n)) { $routes[$Matches.n] = @{} }
    $routes[$Matches.n][$Matches.prop] = $config[$k]
}
if ($routes.Count -eq 0) {
    Add-Line 'No custom static routes configured.'
} else {
    foreach ($n in ($routes.Keys | Sort-Object { [int]$_ })) {
        $r = $routes[$n]
        Add-Line "Route ${n}:"
        foreach ($pair in @(
            @('Src','Source'), @('Dst','Destination'),
            @('Svc','Service'), @('Gateway','Gateway'),
            @('Iface','Interface'), @('Metric','Metric')
        )) {
            if ($r.ContainsKey($pair[0]) -and $r[$pair[0]]) { Add-Line "  $($pair[1]): $($r[$pair[0]])" }
        }
        Add-Line
    }
}

# --- VPN -------------------------------------------------------------------
Add-Section 'VPN CONFIGURATION'
Add-Line 'IPsec Settings:'
Add-Line "  IPsec Enabled: $(Get-Val 'ipsecEnable')"
Add-Line
Add-Line 'VPN Tunnels:'
foreach ($i in (Get-IndexedKey '^ipsecName_\d+$')) {
    $name      = Get-Val "ipsecName_$i"
    $gwAddr    = Get-Val "ipsecGwAddr_$i"
    $disabled  = Get-Val "ipsecSaDisabled_$i"
    $p1Exch    = Get-Val "ipsecP1Exch_$i"
    $p1Dh      = Get-Val "ipsecP1DHGrp_$i"
    $p1Enc     = Get-Val "ipsecPh1CryptAlg_$i"
    $p1Auth    = Get-Val "ipsecPh1AuthAlg_$i"
    $localNet  = Get-Val "ipsecLocalNet_$i"
    $remoteNet = Get-Val "ipsecRemoteNet_$i"

    $exchDesc = switch ($p1Exch) { '1' {'Main Mode'} '2' {'Aggressive Mode'} default {"Mode $p1Exch"} }
    $dhDesc   = switch ($p1Dh)   { '1' {'Group 1'} '2' {'Group 2'} '5' {'Group 5'} '14' {'Group 14'} default {"Group $p1Dh"} }
    $encDesc  = switch ($p1Enc)  { '1' {'DES'} '2' {'3DES'} '3' {'AES-128'} '4' {'AES-192'} '5' {'AES-256'} default {"Alg $p1Enc"} }
    $authDesc = switch ($p1Auth) { '1' {'MD5'} '2' {'SHA1'} '3' {'SHA256'} '4' {'SHA384'} '5' {'SHA512'} default {"Alg $p1Auth"} }

    Add-Line
    Add-Line "  Tunnel: $name"
    $status = if ($disabled -eq 'off') {'Enabled'} else {'Disabled'}
    Add-Line "    Status: $status"
    if ($gwAddr -and $gwAddr -ne '0.0.0.0') { Add-Line "    Gateway: $gwAddr" }
    if ($localNet)  { Add-Line "    Local Network:  $localNet" }
    if ($remoteNet) { Add-Line "    Remote Network: $remoteNet" }
    Add-Line "    Phase 1: $exchDesc, $dhDesc, $encDesc, $authDesc"
}

Add-Line
Add-Line 'SSL VPN Settings:'
Add-Line "  Port: $(Get-Val 'sslvpnSvcPort')"
Add-Line "  User Domain: $(Get-Val 'sslvpnUserDomain')"
if ((Get-Val 'SslvpnsDnsServer1') -and (Get-Val 'SslvpnsDnsServer1') -ne '0.0.0.0') {
    Add-Line "  DNS Server 1: $(Get-Val 'SslvpnsDnsServer1')"
}
if ((Get-Val 'SslvpnsDnsServer2') -and (Get-Val 'SslvpnsDnsServer2') -ne '0.0.0.0') {
    Add-Line "  DNS Server 2: $(Get-Val 'SslvpnsDnsServer2')"
}

# --- Schedules -------------------------------------------------------------
Add-Section 'SCHEDULES'
foreach ($i in (Get-IndexedKey '^schedObjId_\d+$')) {
    Add-Line "Schedule: $(Get-Val "schedObjId_$i")"
}

# --- Summary ---------------------------------------------------------------
Add-Section 'CONFIGURATION SUMMARY'
Add-Line "Interfaces:         $(@($ifaceIds).Count)"
Add-Line "Zones:              $(@(Get-IndexedKey '^zoneObjId_\d+$').Count)"
Add-Line "DHCP Scopes:        $($dhcpScopes.Count)"
Add-Line "Static DHCP Leases: $leaseCount"
Add-Line "NAT Policies:       $natCount"
Add-Line "Firewall Rules:     $ruleCount"
Add-Line "Schedules:          $(@(Get-IndexedKey '^schedObjId_\d+$').Count)"

# --- Write -----------------------------------------------------------------
$sb.ToString() | Set-Content -LiteralPath $OutputFile -Encoding UTF8
Write-Host "Done. Wrote $OutputFile."
