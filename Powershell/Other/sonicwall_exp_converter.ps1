# SonicWall .exp to Human-Readable Config Converter
# Comprehensive migration export - captures all user-configured settings
# Usage: .\sonicwall_exp_converter.ps1 -InputFile "path\to\file.exp" -OutputFile "path\to\output.txt"

param(
    [string]$InputFile = "C:\Users\DeanThomas\Downloads\sonicwall-TZ_300-6_5_4_15-117n-1767571633.exp",
    [string]$OutputFile = "C:\Users\DeanThomas\Downloads\sonicwall_essential_config.txt"
)

Add-Type -AssemblyName System.Web

Write-Host "Reading and decoding $InputFile..."

# Read and decode base64
$content = (Get-Content $InputFile -Raw).Trim().TrimEnd('&')
$decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($content))

# Parse into key=value pairs
$lines = $decoded -split '&'
$config = @{}
foreach ($line in $lines) {
    $decodedLine = [System.Web.HttpUtility]::UrlDecode($line)
    if ($decodedLine -match "^(.+?)=(.*)$") {
        $config[$matches[1]] = $matches[2]
    }
}

Write-Host "Parsed $($config.Count) configuration parameters"

$output = @()

function Add-Section($title) {
    $script:output += ""
    $script:output += "=" * 80
    $script:output += $title
    $script:output += "=" * 80
}

$output += "================================================================================"
$output += "SONICWALL CONFIGURATION EXPORT - ESSENTIAL FOR MIGRATION"
$output += "Firmware: $($config['buildNum'])"
$output += "Device: $($config['shortProdName'])"
$output += "================================================================================"

#region ZONES
Add-Section "ZONES"
$zoneIds = $config.Keys | Where-Object { $_ -match "^zoneObjId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
foreach ($zid in $zoneIds) {
    $idx = $zid -replace '\D', ''
    $name = $config["zoneObjId_$idx"]
    $type = $config["zoneObjZoneType_$idx"]
    $typeDesc = switch($type) { "0" {"Untrusted"} "1" {"Trusted"} "2" {"Public"} "3" {"Wireless"} "4" {"Encrypted"} "5" {"SSLVPN"} default {"Type $type"} }
    $output += "Zone: $name ($typeDesc)"
}
#endregion

#region INTERFACES
Add-Section "INTERFACES"
$ifaceNums = @()
$config.Keys | Where-Object { $_ -match "^iface_name_(\d+)$" } | ForEach-Object {
    if ($_ -match "^iface_name_(\d+)$") { $ifaceNums += $matches[1] }
}
foreach ($num in ($ifaceNums | Sort-Object { [int]$_ })) {
    $name = $config["iface_name_$num"]
    $comment = $config["iface_comment_$num"]
    $ip = $config["iface_static_ip_$num"]
    $mask = $config["iface_static_mask_$num"]
    $gateway = $config["iface_static_gateway_$num"]
    $zone = $config["iface_zone_$num"]
    $mode = $config["iface_mode_$num"]
    $vlan = $config["iface_vlanId_$num"]
    $mtu = $config["iface_mtu_$num"]
    $mgmt = $config["iface_mgmt_$num"]
    $modeDesc = switch($mode) { "0" {"Static"} "1" {"DHCP"} "2" {"PPPoE"} "3" {"PPTP"} "4" {"L2TP"} default {"Mode $mode"} }

    if ($name -or $ip -or $comment) {
        $output += "Interface ${num}: $name"
        if ($comment) { $output += "  Description: $comment" }
        if ($zone) { $output += "  Zone: $zone" }
        if ($mode) { $output += "  Mode: $modeDesc" }
        if ($ip -and $ip -ne "0.0.0.0") { $output += "  IP Address: $ip" }
        if ($mask -and $mask -ne "0.0.0.0") { $output += "  Subnet Mask: $mask" }
        if ($gateway -and $gateway -ne "0.0.0.0") { $output += "  Gateway: $gateway" }
        if ($vlan -and $vlan -ne "0") { $output += "  VLAN ID: $vlan" }
        if ($mtu -and $mtu -ne "1500" -and $mtu -ne "0") { $output += "  MTU: $mtu" }
        $output += ""
    }
}
#endregion

#region DNS SETTINGS
Add-Section "DNS SETTINGS"
$output += "DNS Server 1: $($config['dns_server_one'])"
$output += "DNS Server 2: $($config['dns_server_two'])"
$output += "DNS Server 3: $($config['dns_server_three'])"
if ($config['dnsProxy_enable'] -eq 'on') { $output += "DNS Proxy: Enabled" }
if ($config['dnsProxySplit_enable'] -eq 'on') { $output += "Split DNS: Enabled" }
#endregion

#region ADDRESS OBJECTS
Add-Section "ADDRESS OBJECTS (Custom)"
$addrIds = $config.Keys | Where-Object { $_ -match "^addrObjId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
foreach ($aid in $addrIds) {
    $idx = $aid -replace '\D', ''
    $name = $config["addrObjId_$idx"]
    $type = $config["addrObjType_$idx"]
    $zone = $config["addrObjZone_$idx"]
    $ip1 = $config["addrObjIp1_$idx"]
    $ip2 = $config["addrObjIp2_$idx"]
    $fqdn = $config["addrObjFqdn_$idx"]
    $typeDesc = switch($type) { "1" {"Host"} "2" {"Range"} "4" {"Network"} "8" {"MAC"} "16" {"FQDN"} default {"Type $type"} }

    # Skip system/default objects
    $isSystem = $name -match "^(Default|Firewalled|.*Subnets$|.*Interface IP$|All .*|.*Primary.*|U\d+ |.*Enforcement.*|RBL.*|Public Mail.*|Node License.*|Dial-Up.*|SonicPoints|X\d+ (IP|Subnet|Default))"

    if ($name -and -not $isSystem -and (($ip1 -and $ip1 -ne "0.0.0.0") -or $fqdn)) {
        $output += "Name: $name"
        $output += "  Type: $typeDesc"
        if ($zone) { $output += "  Zone: $zone" }
        if ($ip1 -and $ip1 -ne "0.0.0.0") { $output += "  IP/Start: $ip1" }
        if ($ip2 -and $ip2 -ne "0.0.0.0" -and $ip2 -ne $ip1 -and $ip2 -ne "255.255.255.255") { $output += "  End/Mask: $ip2" }
        if ($fqdn) { $output += "  FQDN: $fqdn" }
        $output += ""
    }
}
#endregion

#region ADDRESS GROUPS
Add-Section "ADDRESS GROUPS"
$addrGrpIds = $config.Keys | Where-Object { $_ -match "^addrObjGrpId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
$grpCount = 0
foreach ($gid in $addrGrpIds) {
    $idx = $gid -replace '\D', ''
    $name = $config["addrObjGrpId_$idx"]
    if ($name -and $name -notmatch "^(All |Default|Firewalled)") {
        $grpCount++
        $output += "Group: $name"
    }
}
# Also check ao_atomToGrp for group memberships
$grpMemberships = @{}
$config.Keys | Where-Object { $_ -match "^ao_atomToGrp_\d+$" } | ForEach-Object {
    $idx = $_ -replace '\D', ''
    $member = $config["ao_atomToGrp_$idx"]
    $group = $config["ao_grpToGrp_$idx"]
    if ($group -and $member) {
        if (-not $grpMemberships[$group]) { $grpMemberships[$group] = @() }
        $grpMemberships[$group] += $member
    }
}
foreach ($grp in $grpMemberships.Keys | Sort-Object) {
    if ($grp -notmatch "^(All |Default|Firewalled)") {
        $output += ""
        $output += "Group: $grp"
        foreach ($m in $grpMemberships[$grp]) {
            $output += "  - $m"
        }
    }
}
if ($grpCount -eq 0 -and $grpMemberships.Count -eq 0) {
    $output += "No custom address groups configured."
}
#endregion

#region SERVICE OBJECTS
Add-Section "SERVICE OBJECTS (Custom)"
$svcIds = $config.Keys | Where-Object { $_ -match "^svcObjId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
$customSvcCount = 0
foreach ($sid in $svcIds) {
    $idx = $sid -replace '\D', ''
    $name = $config["svcObjId_$idx"]
    $proto = $config["svcObjIpType_$idx"]
    $port1 = $config["svcObjPort1_$idx"]
    $port2 = $config["svcObjPort2_$idx"]
    $protoDesc = switch($proto) { "6" {"TCP"} "17" {"UDP"} "1" {"ICMP"} "47" {"GRE"} "50" {"ESP"} default {"Proto $proto"} }

    # Only include custom services (IP-based names or specific patterns)
    $isCustom = ($name -match "^\d+\.\d+\.\d+\.\d+") -or ($name -match "^(Camera|Security|Agam|DVR).*Services")

    if ($name -and $isCustom) {
        $customSvcCount++
        $output += "Service: $name"
        $output += "  Protocol: $protoDesc"
        if ($port1) { $output += "  Port Start: $port1" }
        if ($port2 -and $port2 -ne $port1) { $output += "  Port End: $port2" }
        $output += ""
    }
}
if ($customSvcCount -eq 0) {
    $output += "No custom service objects configured."
}
#endregion

#region SERVICE GROUPS
Add-Section "SERVICE GROUPS (Custom)"
$svcGrpMemberships = @{}
$config.Keys | Where-Object { $_ -match "^so_atomToGrp_\d+$" } | ForEach-Object {
    $idx = $_ -replace '\D', ''
    $member = $config["so_atomToGrp_$idx"]
    $group = $config["so_grpToGrp_$idx"]
    if ($group -and $member -and ($group -match "^\d+\.\d+|Camera|Security|Agam|DVR")) {
        if (-not $svcGrpMemberships[$group]) { $svcGrpMemberships[$group] = @() }
        if ($svcGrpMemberships[$group] -notcontains $member) {
            $svcGrpMemberships[$group] += $member
        }
    }
}
if ($svcGrpMemberships.Count -gt 0) {
    foreach ($grp in $svcGrpMemberships.Keys | Sort-Object) {
        $output += "Group: $grp"
        foreach ($m in $svcGrpMemberships[$grp]) {
            $output += "  - $m"
        }
        $output += ""
    }
} else {
    $output += "No custom service groups configured."
}
#endregion

#region DHCP CONFIGURATION
Add-Section "DHCP CONFIGURATION"
$output += "Global Settings:"
$output += "  Domain: $($config['dhcp_domainname'])"
$output += "  Default Lease: $($config['dhcp_lease']) minutes"
$output += "  DNS1: $($config['dhcp_dns0'])"
$output += "  DNS2: $($config['dhcp_dns1'])"
$output += ""

$dhcpScopes = @{}
$dhcpKeys = $config.Keys | Where-Object { $_ -match "^prefs_dhdyn\w+_\d+$" } | Sort-Object
foreach ($key in $dhcpKeys) {
    if ($key -match "^prefs_dhdyn(\w+)_(\d+)$") {
        $prop = $matches[1]
        $num = $matches[2]
        if (-not $dhcpScopes[$num]) { $dhcpScopes[$num] = @{} }
        $dhcpScopes[$num][$prop] = $config[$key]
    }
}
foreach ($num in ($dhcpScopes.Keys | Sort-Object { [int]$_ })) {
    $s = $dhcpScopes[$num]
    $output += "DHCP Scope ${num}:"
    if ($s['scopeactive']) { $output += "  Enabled: $(if($s['scopeactive'] -eq 'on'){'Yes'}else{'No'})" }
    if ($s['start']) { $output += "  Range Start: $($s['start'])" }
    if ($s['end']) { $output += "  Range End: $($s['end'])" }
    if ($s['subnetmask']) { $output += "  Subnet Mask: $($s['subnetmask'])" }
    if ($s['router']) { $output += "  Gateway: $($s['router'])" }
    if ($s['dns0']) { $output += "  DNS1: $($s['dns0'])" }
    if ($s['dns1']) { $output += "  DNS2: $($s['dns1'])" }
    if ($s['domainname']) { $output += "  Domain: $($s['domainname'])" }
    if ($s['lease']) { $output += "  Lease (min): $($s['lease'])" }
    if ($s['DhcpOptGrp']) { $output += "  DHCP Option Group: $($s['DhcpOptGrp'])" }
    $output += ""
}
#endregion

#region STATIC DHCP LEASES
Add-Section "STATIC DHCP LEASES"
$staticLeases = @{}
$staticKeys = $config.Keys | Where-Object { $_ -match "^prefs_dhstatic\w+_\d+$" } | Sort-Object
foreach ($key in $staticKeys) {
    if ($key -match "^prefs_dhstatic(\w+)_(\d+)$") {
        $prop = $matches[1]
        $num = $matches[2]
        if (-not $staticLeases[$num]) { $staticLeases[$num] = @{} }
        $staticLeases[$num][$prop] = $config[$key]
    }
}
$leaseCount = 0
foreach ($num in ($staticLeases.Keys | Sort-Object { [int]$_ })) {
    $s = $staticLeases[$num]
    if ($s['ip'] -or $s['hw']) {
        $leaseCount++
        $output += "Static Lease ${num}:"
        if ($s['name']) { $output += "  Name: $($s['name'])" }
        if ($s['ip']) { $output += "  IP Address: $($s['ip'])" }
        if ($s['hw']) {
            $mac = $s['hw']
            # Format MAC address with colons
            if ($mac.Length -eq 12) {
                $mac = $mac -replace '(.{2})', '$1:' -replace ':$', ''
            }
            $output += "  MAC Address: $mac"
        }
        if ($s['router']) { $output += "  Gateway: $($s['router'])" }
        if ($s['subnetmask']) { $output += "  Subnet: $($s['subnetmask'])" }
        if ($s['scopeactive'] -eq 'on') { $output += "  Active: Yes" }
        $output += ""
    }
}
if ($leaseCount -eq 0) {
    $output += "No static DHCP leases configured."
}
$output += ""
$output += "Total Static Leases: $leaseCount"
#endregion

#region DHCP OPTIONS
Add-Section "DHCP OPTIONS"
$dhcpOptIds = $config.Keys | Where-Object { $_ -match "^dhcpOptionId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
$optCount = 0
foreach ($oid in $dhcpOptIds) {
    $idx = $oid -replace '\D', ''
    $name = $config["dhcpOptionId_$idx"]
    $tagNum = $config["dhcpOptionObjTagNumber_$idx"]
    $tagVal = $config["dhcpOptionObjTagValue_$idx"]
    if ($name -and $tagVal) {
        $optCount++
        $output += "Option: $name"
        $output += "  Tag Number: $tagNum"
        $output += "  Value: $tagVal"
        $output += ""
    }
}
if ($optCount -eq 0) {
    $output += "No custom DHCP options configured."
}
#endregion

#region NAT POLICIES
Add-Section "NAT POLICIES"
$natPols = @{}
$natKeys = $config.Keys | Where-Object { $_ -match "^natPolicy\w+_\d+$" } | Sort-Object
foreach ($key in $natKeys) {
    if ($key -match "^natPolicy(\w+)_(\d+)$") {
        $prop = $matches[1]
        $num = $matches[2]
        if (-not $natPols[$num]) { $natPols[$num] = @{} }
        $natPols[$num][$prop] = $config[$key]
    }
}
$natCount = 0
foreach ($num in ($natPols.Keys | Sort-Object { [int]$_ })) {
    $n = $natPols[$num]
    if (-not $n['OrigSrc'] -and -not $n['OrigDst'] -and -not $n['OrigSvc']) { continue }
    $natCount++
    $output += "NAT Policy ${num}:"
    if ($n['Name']) { $output += "  Name: $($n['Name'])" }
    if ($n['Enabled']) { $output += "  Enabled: $(if($n['Enabled'] -eq '1'){'Yes'}else{'No'})" }
    if ($n['OrigSrc']) { $output += "  Source Original: $($n['OrigSrc'])" }
    if ($n['TransSrc']) { $output += "  Source Translated: $($n['TransSrc'])" }
    if ($n['OrigDst']) { $output += "  Dest Original: $($n['OrigDst'])" }
    if ($n['TransDst']) { $output += "  Dest Translated: $($n['TransDst'])" }
    if ($n['OrigSvc']) { $output += "  Service Original: $($n['OrigSvc'])" }
    if ($n['TransSvc']) { $output += "  Service Translated: $($n['TransSvc'])" }
    if ($n['Comment']) { $output += "  Comment: $($n['Comment'])" }
    $output += ""
}
$output += "Total NAT Policies: $natCount"
#endregion

#region FIREWALL ACCESS RULES
Add-Section "FIREWALL ACCESS RULES"
$policies = @{}
$policyKeys = $config.Keys | Where-Object { $_ -match "^policy\w+_\d+$" } | Sort-Object
foreach ($key in $policyKeys) {
    if ($key -match "^policy(\w+)_(\d+)$") {
        $prop = $matches[1]
        $num = $matches[2]
        if (-not $policies[$num]) { $policies[$num] = @{} }
        $policies[$num][$prop] = $config[$key]
    }
}
$ruleCount = 0
foreach ($num in ($policies.Keys | Sort-Object { [int]$_ })) {
    $p = $policies[$num]
    $ruleCount++
    $actionDesc = switch($p['Action']) { "0" {"Deny"} "1" {"Discard"} "2" {"Allow"} default {"Action $($p['Action'])"} }
    $output += "Rule ${num}:"
    if ($p['Name']) { $output += "  Name: $($p['Name'])" }
    if ($p['Enabled']) { $output += "  Enabled: $(if($p['Enabled'] -eq '1'){'Yes'}else{'No'})" }
    if ($p['Action']) { $output += "  Action: $actionDesc" }
    if ($p['SrcZone']) { $output += "  Source Zone: $($p['SrcZone'])" }
    if ($p['DstZone']) { $output += "  Dest Zone: $($p['DstZone'])" }
    if ($p['SrcNet']) { $output += "  Source: $($p['SrcNet'])" }
    if ($p['DstNet']) { $output += "  Destination: $($p['DstNet'])" }
    if ($p['SrcSvc']) { $output += "  Source Service: $($p['SrcSvc'])" }
    if ($p['DstSvc']) { $output += "  Dest Service: $($p['DstSvc'])" }
    if ($p['Time']) { $output += "  Schedule: $($p['Time'])" }
    if ($p['Comment']) { $output += "  Comment: $($p['Comment'])" }
    if ($p['DefaultRule'] -eq "1") { $output += "  [DEFAULT RULE]" }
    if ($p['Management'] -eq "1") { $output += "  [MANAGEMENT RULE]" }
    $output += ""
}
$output += "Total Firewall Rules: $ruleCount"
#endregion

#region ROUTING
Add-Section "ROUTING / STATIC ROUTES"
$output += "(Default routes are defined by interface gateways - see INTERFACES section)"
$output += ""
$routes = @{}
$routeKeys = $config.Keys | Where-Object { $_ -match "^routePol\w+_\d+$" } | Sort-Object
foreach ($key in $routeKeys) {
    if ($key -match "^routePol(\w+)_(\d+)$") {
        $prop = $matches[1]
        $num = $matches[2]
        if (-not $routes[$num]) { $routes[$num] = @{} }
        $routes[$num][$prop] = $config[$key]
    }
}
if ($routes.Count -eq 0) {
    $output += "No custom static routes configured."
} else {
    foreach ($num in ($routes.Keys | Sort-Object { [int]$_ })) {
        $r = $routes[$num]
        $output += "Route ${num}:"
        if ($r['Src']) { $output += "  Source: $($r['Src'])" }
        if ($r['Dst']) { $output += "  Destination: $($r['Dst'])" }
        if ($r['Svc']) { $output += "  Service: $($r['Svc'])" }
        if ($r['Gateway']) { $output += "  Gateway: $($r['Gateway'])" }
        if ($r['Iface']) { $output += "  Interface: $($r['Iface'])" }
        if ($r['Metric']) { $output += "  Metric: $($r['Metric'])" }
        $output += ""
    }
}
#endregion

#region VPN CONFIGURATION
Add-Section "VPN CONFIGURATION"

# IPsec Global Settings
$output += "IPsec Settings:"
$output += "  IPsec Enabled: $($config['ipsecEnable'])"
$output += ""

# VPN Tunnels
$output += "VPN Tunnels:"
$vpnNames = $config.Keys | Where-Object { $_ -match "^ipsecName_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
foreach ($vn in $vpnNames) {
    $idx = $vn -replace '\D', ''
    $name = $config["ipsecName_$idx"]
    $gwAddr = $config["ipsecGwAddr_$idx"]
    $enabled = $config["ipsecSaDisabled_$idx"]
    $p1Exch = $config["ipsecP1Exch_$idx"]
    $p1Dh = $config["ipsecP1DHGrp_$idx"]
    $p1Enc = $config["ipsecPh1CryptAlg_$idx"]
    $p1Auth = $config["ipsecPh1AuthAlg_$idx"]
    $p2Enc = $config["ipsecPh2CryptAlg_$idx"]
    $p2Auth = $config["ipsecPh2AuthAlg_$idx"]
    $localNet = $config["ipsecLocalNet_$idx"]
    $remoteNet = $config["ipsecRemoteNet_$idx"]

    $exchDesc = switch($p1Exch) { "1" {"Main Mode"} "2" {"Aggressive Mode"} default {"Mode $p1Exch"} }
    $dhDesc = switch($p1Dh) { "1" {"Group 1"} "2" {"Group 2"} "5" {"Group 5"} "14" {"Group 14"} default {"Group $p1Dh"} }
    $encDesc = switch($p1Enc) { "1" {"DES"} "2" {"3DES"} "3" {"AES-128"} "4" {"AES-192"} "5" {"AES-256"} default {"Alg $p1Enc"} }
    $authDesc = switch($p1Auth) { "1" {"MD5"} "2" {"SHA1"} "3" {"SHA256"} "4" {"SHA384"} "5" {"SHA512"} default {"Alg $p1Auth"} }

    $output += ""
    $output += "  Tunnel: $name"
    if ($enabled -eq 'off') { $output += "    Status: Enabled" } else { $output += "    Status: Disabled" }
    if ($gwAddr -and $gwAddr -ne "0.0.0.0") { $output += "    Gateway: $gwAddr" }
    if ($localNet) { $output += "    Local Network: $localNet" }
    if ($remoteNet) { $output += "    Remote Network: $remoteNet" }
    $output += "    Phase 1: $exchDesc, $dhDesc, $encDesc, $authDesc"
}

# SSL VPN
$output += ""
$output += "SSL VPN Settings:"
$output += "  Port: $($config['sslvpnSvcPort'])"
$output += "  User Domain: $($config['sslvpnUserDomain'])"
if ($config['SslvpnsDnsServer1'] -and $config['SslvpnsDnsServer1'] -ne "0.0.0.0") {
    $output += "  DNS Server 1: $($config['SslvpnsDnsServer1'])"
}
if ($config['SslvpnsDnsServer2'] -and $config['SslvpnsDnsServer2'] -ne "0.0.0.0") {
    $output += "  DNS Server 2: $($config['SslvpnsDnsServer2'])"
}
#endregion

#region SCHEDULES
Add-Section "SCHEDULES"
$schedIds = $config.Keys | Where-Object { $_ -match "^schedObjId_\d+$" } | Sort-Object { [int]($_ -replace '\D', '') }
foreach ($sid in $schedIds) {
    $idx = $sid -replace '\D', ''
    $name = $config["schedObjId_$idx"]
    $output += "Schedule: $name"
}
#endregion

#region SUMMARY
Add-Section "CONFIGURATION SUMMARY"
$output += "Interfaces: $($ifaceNums.Count)"
$output += "Zones: $($zoneIds.Count)"
$output += "DHCP Scopes: $($dhcpScopes.Count)"
$output += "Static DHCP Leases: $leaseCount"
$output += "NAT Policies: $natCount"
$output += "Firewall Rules: $ruleCount"
$output += "Schedules: $($schedIds.Count)"
#endregion

$output | Out-File -FilePath $OutputFile -Encoding UTF8
Write-Host "Done! Essential config written to: $OutputFile"
Write-Host "Total lines: $($output.Count)"
