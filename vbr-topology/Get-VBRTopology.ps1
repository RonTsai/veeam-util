<#
.SYNOPSIS
  Scans the Veeam backup infrastructure from the VBR server and draws a
  "Backup architecture: data movers" diagram.

.DESCRIPTION
  Uses the Veeam PowerShell module (Veeam.Backup.PowerShell, VBR v12+) to read
  managed servers, hypervisors, proxies, repositories, SOBRs, object storage,
  WAN accelerators, tape servers, agent protection groups and jobs. It works out
  the data flow, detects Enterprise Manager / Veeam ONE, finds which ESXi or
  Hyper-V host each component runs on, and writes an interactive HTML diagram.
  Read-only: only Get-* / Find-* cmdlets are called.

.EXAMPLE
  # Run on the VBR server as the current user (must be a VBR administrator)
  .\Get-VBRTopology.ps1

.EXAMPLE
  # Add an Enterprise Manager manually (when auto-detection finds nothing)
  .\Get-VBRTopology.ps1 -EnterpriseManager em01.corp.local

.EXAMPLE
  # Use PowerCLI to find the ESXi host of each component (matches guest hostname / IP)
  .\Get-VBRTopology.ps1 -UsePowerCLI -VCenterUser readonly@vsphere.local

.EXAMPLE
  # Different vCenter logins per vCenter (no prompts, e.g. for scheduled runs)
  .\Get-VBRTopology.ps1 -UsePowerCLI -VCenterCredentialMap @{ "vc01.corp.local" = $cred1; "vc02.corp.local" = $cred2 }

.EXAMPLE
  # Choose the output folder, or connect to another VBR (requires the VBR Console)
  .\Get-VBRTopology.ps1 -Server vbr02.corp.local -Credential (Get-Credential) -OutDir C:\Temp\vbr
#>
[CmdletBinding()]
param(
    [string]$Server = "localhost",
    [pscredential]$Credential,
    [string]$OutDir = (Join-Path $PSScriptRoot "out"),
    [string]$Template = (Join-Path $PSScriptRoot "template.html"),
    # Enterprise Manager host(s) to add when auto-detection finds nothing
    [string[]]$EnterpriseManager = @(),
    # Manual component -> host map, CSV columns Component,Host[,VM]; highest priority
    [string]$PlacementCsv,
    # Query vCenter with VMware PowerCLI (matches guest DNS name / IP; more accurate, needs PowerCLI)
    [switch]$UsePowerCLI,
    # vCenter login for -UsePowerCLI; when omitted, the script asks for it and names the vCenter
    [pscredential]$VCenterCredential,
    # Pre-fills the user name in that prompt
    [string]$VCenterUser,
    # Per-vCenter logins, e.g. @{ "vc01.corp.local" = $cred1; "vc02.corp.local" = $cred2 }.
    # vCenters not in the map use -VCenterCredential (or the prompt).
    [hashtable]$VCenterCredentialMap = @{},
    # By default each run writes to <OutDir>\<VBR name>_<time>; with this switch, <OutDir> is overwritten
    [switch]$NoTimestamp,
    # Default report language; viewers can switch it in the report
    [ValidateSet("zh-TW", "en")]
    [string]$Language = "zh-TW"
)

$ErrorActionPreference = "Stop"
$script:Warnings = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-Safe {
    param([string]$Name, [scriptblock]$Script)
    try {
        $r = @(& $Script)
        Write-Host ("  [OK]   {0,-28} {1}" -f $Name, $r.Count)
        return , $r
    } catch {
        Write-Host ("  [skip] {0,-28} {1}" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
        $script:Warnings.Add("${Name}: $($_.Exception.Message)")
        return , @()
    }
}

# Try property paths in order (names differ between versions); return the first non-empty value
function Get-Prop {
    param($Obj, [string[]]$Names)
    foreach ($n in $Names) {
        $cur = $Obj
        foreach ($part in $n.Split(".")) {
            if ($null -eq $cur) { break }
            try { $cur = $cur.$part } catch { $cur = $null }
        }
        if ($null -ne $cur -and "$cur" -ne "") { return $cur }
    }
    return $null
}

function Get-IdStr($x) { if ($null -eq $x) { return $null }; if ($x.Id) { return $x.Id.ToString() }; return $x.ToString() }

$Nodes = [ordered]@{}
$Links = [ordered]@{}
$UsedHosts = New-Object System.Collections.Generic.HashSet[string]

function Test-Node($Id) { return ($null -ne $Id -and "$Id" -ne "" -and $Nodes.Contains("$Id")) }

function Add-Node {
    param([string]$Id, [string]$Kind, [string]$Name, [string]$Sub = "", [string[]]$Badges = @(), $Details = @{})
    if (-not $Nodes.Contains($Id)) {
        $d = [ordered]@{}
        foreach ($k in $Details.Keys) { if ($null -ne $Details[$k] -and "$($Details[$k])" -ne "") { $d[$k] = "$($Details[$k])" } }
        $Nodes[$Id] = [ordered]@{ id = $Id; kind = $Kind; name = $Name; sub = $Sub; badges = @($Badges); details = $d }
    }
    return $Nodes[$Id]
}

function Add-Link {
    param([string]$Source, [string]$Target, [string]$Job, [string]$Kind = "data")
    if (-not $Source -or -not $Target -or $Source -eq $Target) { return }
    if (-not (Test-Node $Source) -or -not (Test-Node $Target)) { return }
    $key = "$Source|$Target"
    if (-not $Links.Contains($key)) {
        $Links[$key] = [ordered]@{ source = $Source; target = $Target; kind = $Kind; jobs = New-Object System.Collections.Generic.List[string] }
    } elseif ($Kind -eq "data") { $Links[$key].kind = "data" }
    if ($Job -and -not $Links[$key].jobs.Contains($Job)) { $Links[$key].jobs.Add($Job) }
}

function Format-GB($v) { if ($null -eq $v) { return $null }; return ("{0:N0} GB" -f [double]$v) }

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------

if (-not (Get-Command Get-VBRServer -ErrorAction SilentlyContinue)) {
    try { Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue }
    catch {
        try { Add-PSSnapin VeeamPSSnapIn } catch { throw "Veeam PowerShell module not found. Run this on the VBR server or a machine with the VBR Console installed." }
    }
}
$connected = $false
$session = $null
try { $session = Get-VBRServerSession } catch { }
if (-not $session) {
    Write-Host "Connecting to VBR: $Server ..."
    if ($Credential) { Connect-VBRServer -Server $Server -Credential $Credential }
    else { Connect-VBRServer -Server $Server }
    $connected = $true
}

Write-Host "Scanning:"

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------

$servers     = Invoke-Safe "Get-VBRServer"                 { Get-VBRServer }
$viProxies   = Invoke-Safe "Get-VBRViProxy"                { Get-VBRViProxy }
$hvProxies   = Invoke-Safe "Get-VBRHvProxy"                { Get-VBRHvProxy }
$gpProxies   = Invoke-Safe "Get-VBRNASProxyServer"         { Get-VBRNASProxyServer }
$wans        = Invoke-Safe "Get-VBRWANAccelerator"         { Get-VBRWANAccelerator }
$repos       = Invoke-Safe "Get-VBRBackupRepository"       { Get-VBRBackupRepository }
$sobrs       = Invoke-Safe "Get-VBRBackupRepository -SO"   { Get-VBRBackupRepository -ScaleOut }
$objRepos    = Invoke-Safe "Get-VBRObjectStorageRepository" { Get-VBRObjectStorageRepository }
# Application Backup Repositories (v13): Get-VBRBackupRepository does not return them
$abrRepos    = Invoke-Safe "Get-VBRApplicationBackupRepository" {
    if (Get-Command Get-VBRApplicationBackupRepository -ErrorAction SilentlyContinue) { Get-VBRApplicationBackupRepository } }
$tapes       = Invoke-Safe "Get-VBRTapeServer"             { Get-VBRTapeServer }
$pgs         = Invoke-Safe "Get-VBRProtectionGroup"        { Get-VBRProtectionGroup }
$jobs        = Invoke-Safe "Get-VBRJob"                    { Get-VBRJob -WarningAction SilentlyContinue }
$agentJobs   = Invoke-Safe "Get-VBRComputerBackupJob"      { Get-VBRComputerBackupJob }
$copyJobs    = Invoke-Safe "Get-VBRBackupCopyJob"          { Get-VBRBackupCopyJob }
$nasJobs     = Invoke-Safe "Unstructured / NAS backup job" {
    # Renamed to Get-VBRUnstructuredBackupJob in v12.1+; older versions only have Get-VBRNASBackupJob
    if (Get-Command Get-VBRUnstructuredBackupJob -ErrorAction SilentlyContinue) { Get-VBRUnstructuredBackupJob }
    else { Get-VBRNASBackupJob -WarningAction SilentlyContinue }
}
# Listed in the Jobs table only (no data-flow links); older versions lack these cmdlets
$entraJobs   = Invoke-Safe "Get-VBREntraIDTenantBackupJob" {
    if (Get-Command Get-VBREntraIDTenantBackupJob -ErrorAction SilentlyContinue) { Get-VBREntraIDTenantBackupJob }
}
$sbJobs      = Invoke-Safe "Get-VBRSureBackupJob"          {
    if (Get-Command Get-VBRSureBackupJob -ErrorAction SilentlyContinue) { Get-VBRSureBackupJob }
}
$vlabs       = Invoke-Safe "Get-VBRVirtualLab"             {
    if (Get-Command Get-VBRVirtualLab -ErrorAction SilentlyContinue) { Get-VBRVirtualLab }
}
$tapeLibs    = Invoke-Safe "Get-VBRTapeLibrary"            { Get-VBRTapeLibrary }
$tapeJobs    = Invoke-Safe "Get-VBRTapeJob"                { Get-VBRTapeJob }
$cloudProvs  = Invoke-Safe "Get-VBRCloudProvider"          {
    if (Get-Command Get-VBRCloudProvider -ErrorAction SilentlyContinue) { Get-VBRCloudProvider }
}
$cdpProxies  = Invoke-Safe "Get-VBRCDPProxy"               {
    if (Get-Command Get-VBRCDPProxy -ErrorAction SilentlyContinue) { Get-VBRCDPProxy }
}
$cdpPolicies = Invoke-Safe "Get-VBRCDPPolicy"              {
    if (Get-Command Get-VBRCDPPolicy -ErrorAction SilentlyContinue) { Get-VBRCDPPolicy }
}
$vcdReplicas = Invoke-Safe "Get-VBRvCDReplicaJob"          {
    if (Get-Command Get-VBRvCDReplicaJob -ErrorAction SilentlyContinue) { Get-VBRvCDReplicaJob }
}
# Get-VBRUnstructuredBackupJob also returns these two; they only tell which of its jobs they are
$entraLogJobs = Invoke-Safe "Get-VBREntraIDLogsBackupJob"  {
    if (Get-Command Get-VBREntraIDLogsBackupJob -ErrorAction SilentlyContinue) { Get-VBREntraIDLogsBackupJob }
}
$nasCopyJobs = Invoke-Safe "Get-VBRNASBackupCopyJob"       {
    if (Get-Command Get-VBRNASBackupCopyJob -ErrorAction SilentlyContinue) { Get-VBRNASBackupCopyJob -WarningAction SilentlyContinue }
}
$cfgJobs     = Invoke-Safe "Get-VBRConfigurationBackupJob" { Get-VBRConfigurationBackupJob }
$backups     = Invoke-Safe "Get-VBRBackup"                 { Get-VBRBackup }

$build = $null
try { $build = (Get-VBRBackupServerInfo).Build.ToString() } catch { }
if (-not $build) {
    try {
        $dll = Join-Path ${env:ProgramFiles} "Veeam\Backup and Replication\Console\Veeam.Backup.Core.dll"
        $build = (Get-Item $dll).VersionInfo.ProductVersion
    } catch { }
}
# The backup server is the host of the active session (the Veeam PowerShell Toolkit window is already
# connected when it opens), else -Server. Only a local connection makes this machine the backup server;
# from a remote console, this machine is not part of the VBR infrastructure.
$localNames = @("localhost", ".", "127.0.0.1", "::1")
$vbrName = $Server
if ($session) {
    $sv = "$(Get-Prop $session @('Server', 'ServerName'))"
    if ($sv -and $sv -notin $localNames) { $vbrName = $sv }
}
$vbrLocal = $vbrName -in $localNames
$vbrConnectedAs = $null
$ipTmp = $null
if ($vbrLocal) {
    try { $vbrName = [System.Net.Dns]::GetHostEntry([Environment]::MachineName).HostName } catch { $vbrName = [Environment]::MachineName }
} else {
    # An IP or a short name / alias (e.g. "vbr"): use the DNS name of its address (forward, then reverse
    # lookup), so the report shows the real host. Keep the name as given when DNS has nothing better.
    $isIp = [System.Net.IPAddress]::TryParse($vbrName, [ref]$ipTmp)
    if ($isIp -or $vbrName -notmatch '\.') {
        try {
            $addr = if ($isIp) { $ipTmp } else { @([System.Net.Dns]::GetHostAddresses($vbrName) | Where-Object { $_.AddressFamily -eq "InterNetwork" })[0] }
            $ptr = "$([System.Net.Dns]::GetHostEntry($addr).HostName)"
            if ($ptr -and $ptr -ine $vbrName -and -not [System.Net.IPAddress]::TryParse($ptr, [ref]$ipTmp) -and ($isIp -or $ptr -match '\.')) {
                $vbrConnectedAs = $vbrName; $vbrName = $ptr
            }
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Build nodes
# ---------------------------------------------------------------------------

Add-Node "vbr" "backup" $vbrName "Backup server · v$build" @() @{ Build = $build; Server = $vbrName; "Connected as" = $vbrConnectedAs } | Out-Null

# ---- Enterprise Manager / Veeam ONE (management tier)
# There is no official cmdlet that returns the EM a VBR is registered to. Use the
# internal API that community tools rely on, plus a local service check and the
# -EnterpriseManager parameter.
$mgmtSeen = @{}
function Add-Mgmt([string]$Kind, [string]$Name, [string]$Sub, $Details) {
    if (-not $Name) { return }
    $key = "${Kind}:$($Name.ToLower())"
    if ($mgmtSeen[$key]) { foreach ($k in $Details.Keys) { if ($Details[$k]) { $Nodes[$mgmtSeen[$key]].details[$k] = "$($Details[$k])" } }; return }
    if ($Name -ieq $vbrName -or ($vbrLocal -and $Name -ieq [Environment]::MachineName)) { $Sub += " · same host as VBR" }
    $id = "mgmt:$key"; $mgmtSeen[$key] = $id
    Add-Node $id $Kind $Name $Sub @() $Details | Out-Null
}

$emInfo = $null
try { $emInfo = [Veeam.Backup.Core.SBackupOptions]::GetEnterpriseServerInfo() } catch {
    $script:Warnings.Add("Enterprise Manager auto-detection (SBackupOptions.GetEnterpriseServerInfo) failed: $($_.Exception.Message)")
}
foreach ($e in @($emInfo)) {
    if (-not $e) { continue }
    $url = Get-Prop $e @("URL", "Url", "ServerUrl", "EnterpriseServerUrl")
    $name = Get-Prop $e @("ServerName", "Name", "HostName", "EnterpriseServerName")
    if (-not $name -and $url) { try { $name = ([uri]"$url").Host } catch { } }
    $det = [ordered]@{ Source = "VBR registration"; URL = $url }
    foreach ($pp in $e.PSObject.Properties) {
        $v = $pp.Value
        if ($null -ne $v -and ($v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [guid] -or $v -is [datetime])) { $det[$pp.Name] = "$v" }
    }
    $emConn = Get-Prop $e @("IsConnected", "Connected")
    if ($name) { Add-Mgmt "em" $name ("Enterprise Manager" + $(if ($emConn -eq $false) { " · not connected" } else { "" })) $det }
}
Write-Host ("  [OK]   {0,-28} {1}" -f "Enterprise Manager", $mgmtSeen.Count)

try {
    $svcs = @(Get-Service -ErrorAction SilentlyContinue)
    if ($svcs | Where-Object { $_.DisplayName -match "Enterprise Manager" -or $_.Name -match "VeeamEnterpriseManager" }) {
        Add-Mgmt "em" $vbrName "Enterprise Manager" @{ Source = "Local service" }
    }
    $vone = $svcs | Where-Object { $_.DisplayName -match "^Veeam ONE" } | Select-Object -First 1
    if ($vone) { Add-Mgmt "vone" $vbrName "Veeam ONE" @{ Source = "Local service"; Service = $vone.DisplayName } }
} catch { }
foreach ($m in $EnterpriseManager) { Add-Mgmt "em" $m "Enterprise Manager" @{ Source = "Manual (-EnterpriseManager)" } }

# Plug-in platforms (ExternalInfrastructureServer) carry no type field; the platform ID is the
# "_platform_<guid>" suffix of their physical host name. Unknown IDs show as "Plug-in platform".
$PluginPlatforms = @{
    "01208ee8-47fe-4ea8-8727-5115874da1ad" = "Proxmox VE"
    "799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2" = "Nutanix AHV"
    "2d470d24-b6bb-4fa3-b7ff-f0fc1137ca52" = "HPE Morpheus VME"
}
# "VMware ESXi 8.0.3 build-25595708" -> Product / Version / Build
function Get-ViVersion($Server) {
    $txt = "$(Get-Prop $Server @('Info.Info'))"
    if ($txt -match '^(.*?)\s+(\d+(?:\.\d+)+)\s+build-(\d+)') { return @{ Product = $Matches[1]; Version = $Matches[2]; Build = $Matches[3] } }
    return $null
}

$serverById = @{}; $serverByName = @{}
$esxiVersions = @{}
foreach ($s in $servers) {
    $id = Get-IdStr $s; $t = "$($s.Type)"
    $serverById[$id] = $s; $serverByName[$s.Name.ToLower()] = $s
    $det = @{ Type = $t; Description = $s.Description; Status = $(if ($s.IsUnavailable) { "Unavailable" } else { "Available" }) }
    if ($s.Name -ieq $vbrName -or $t -eq "Local" -or ($vbrLocal -and $s.Name -ieq [Environment]::MachineName)) { [void]$UsedHosts.Add($id) }
    $ver = ""
    if ($t -match '^(VC|ESXi?)$') {
        $v = Get-ViVersion $s
        if ($v) {
            $det["Product"] = $v.Product; $det["Version"] = $v.Version; $det["Build"] = $v.Build; $ver = " $($v.Version)"
            if ($t -ne "VC") { $esxiVersions[$v.Version] = 1 + [int]$esxiVersions[$v.Version] }
        }
    }
    switch -Regex ($t) {
        '^VC$'           { Add-Node $id "vi_host" $s.Name "vCenter Server$ver · Source host" @() $det | Out-Null; [void]$UsedHosts.Add($id) }
        '^ESXi?$'        { Add-Node $id "vi_host" $s.Name "ESXi$ver · Source host" @() $det | Out-Null; [void]$UsedHosts.Add($id) }
        '^ExternalInfrastructureServer$' {
            $platId = $null
            try { if ("$($s.GetPhysicalHost().Name)" -match '_platform_([0-9a-fA-F-]{36})$') { $platId = $Matches[1].ToLower() } } catch { }
            $plat = if ($platId -and $PluginPlatforms.ContainsKey($platId)) { $PluginPlatforms[$platId] } else { "Plug-in platform" }
            $det["Platform"] = $plat; $det["Platform ID"] = $platId
            Add-Node $id "ext_host" $s.Name "$plat · Source host" @() $det | Out-Null; [void]$UsedHosts.Add($id)
        }
        'Vcd|CloudDir'   { Add-Node $id "vi_host" $s.Name "VMware Cloud Director" @() $det | Out-Null; [void]$UsedHosts.Add($id) }
        '^Hv(Server|Host)$' { $det["Data Mover"] = "On-host proxy (Veeam Data Mover Service)"
                           Add-Node $id "hv_host" $s.Name "Hyper-V host · Source host" @("M") $det | Out-Null; [void]$UsedHosts.Add($id) }
        '^HvCluster$'    { Add-Node $id "hv_host" $s.Name "Hyper-V cluster · Source host" @("M") $det | Out-Null; [void]$UsedHosts.Add($id) }
        '^Scvmm$'        { Add-Node $id "hv_host" $s.Name "SCVMM · Source host" @("M") $det | Out-Null; [void]$UsedHosts.Add($id) }
    }
}
if ($esxiVersions.Count -gt 1) {
    $vlist = ($esxiVersions.Keys | Sort-Object { [version]$_ } -Descending | ForEach-Object { "$_ × $($esxiVersions[$_])" }) -join ", "
    $script:Warnings.Add("ESXi hosts run different versions: $vlist")
}
if (@($Nodes.Values | Where-Object { $_.kind -eq "ext_host" }).Count) {
    $script:Warnings.Add("Proxies of plug-in platforms (Proxmox VE, Nutanix AHV, HPE Morpheus VME) cannot be read through PowerShell or the REST API and are not shown.")
}

function Resolve-HostName($obj) {
    $h = Get-Prop $obj @("Host.Name", "Server.Name")
    if ($h) { return $h }
    try { $h = $obj.GetHost().Name; if ($h) { return $h } } catch { }
    $hid = Get-Prop $obj @("HostId", "Host.Id", "Server.Id")
    if ($hid -and $serverById.ContainsKey("$hid")) { return $serverById["$hid"].Name }
    return $null
}
function Resolve-HostId($obj) {
    $hid = Get-Prop $obj @("Host.Id", "HostId", "Server.Id")
    if ($hid) { return "$hid" }
    try { return $obj.GetHost().Id.ToString() } catch { return $null }
}

$proxyByType = @{ ViProxy = @(); HvProxy = @(); GeneralPurposeProxy = @(); CdpProxy = @() }

foreach ($p in $viProxies) {
    $id = Get-IdStr $p; [void]$UsedHosts.Add((Resolve-HostId $p))
    Add-Node $id "proxy" $p.Name "VMware backup proxy" @("M") @{
        Type = "ViProxy"; Host = (Resolve-HostName $p); "Transport mode" = (Get-Prop $p @("Options.TransportMode", "TransportMode"))
        "Max tasks" = (Get-Prop $p @("Options.MaxTasksCount", "MaxTasksCount")); Disabled = $p.IsDisabled; Description = $p.Description } | Out-Null
    $proxyByType.ViProxy += $id
}
foreach ($p in $hvProxies) {
    $id = Get-IdStr $p; $ptype = "$($p.Type)"
    $hid = Resolve-HostId $p; [void]$UsedHosts.Add($hid)
    if ($ptype -match "OnHost") { continue }   # an on-host proxy is the Hyper-V host itself
    Add-Node $id "proxy" $p.Name "Hyper-V off-host proxy" @("M") @{
        Type = "HvProxy ($ptype)"; Host = (Resolve-HostName $p); "Max tasks" = (Get-Prop $p @("MaxTasksCount", "Options.MaxTasksCount")) } | Out-Null
    $proxyByType.HvProxy += $id
}
foreach ($p in $gpProxies) {
    $srv = Get-Prop $p @("Server"); $id = "gp:" + (Get-IdStr $p)
    $name = Get-Prop $p @("Server.Name", "Name")
    [void]$UsedHosts.Add((Get-IdStr $srv))
    Add-Node $id "proxy" $name "General-purpose proxy" @("M") @{ Type = "GeneralPurposeProxy"; "Max tasks" = (Get-Prop $p @("ConcurrentTaskNumber", "MaxTasksCount")) } | Out-Null
    $proxyByType.GeneralPurposeProxy += $id
}
# CDP proxies (VMware CDP), named after their server as general-purpose proxies are
foreach ($p in $cdpProxies) {
    $sid = "$(Get-Prop $p @('ServerId', 'Server.Id'))"
    $srv = $(if ($sid -and $serverById.ContainsKey($sid)) { $serverById[$sid] } else { $null })
    if ($sid) { [void]$UsedHosts.Add($sid) }
    $id = "cdp:" + (Get-IdStr $p)
    $en = Get-Prop $p @("IsEnabled", "Enabled")
    $cache = "$(Get-Prop $p @('CacheSize'))"; $unit = "$(Get-Prop $p @('CacheSizeUnit'))"
    Add-Node $id "proxy" $(if ($srv) { $srv.Name } else { $p.Name }) "CDP proxy" @("M") @{
        Type = "CdpProxy"; Host = $(if ($srv) { $srv.Name } else { $null }); "Cache path" = (Get-Prop $p @("CachePath"))
        "Cache size" = $(if ($cache -and $unit) { "$cache $unit" } else { $cache }); Disabled = $(if ($null -ne $en) { -not $en } else { $null })
        Description = $p.Description } | Out-Null
    $proxyByType.CdpProxy += $id
}
foreach ($w in $wans) {
    $id = Get-IdStr $w; [void]$UsedHosts.Add((Resolve-HostId $w))
    Add-Node $id "proxy" $w.Name "WAN accelerator" @("M") @{ Host = (Resolve-HostName $w); Description = $w.Description } | Out-Null
}
foreach ($t in $tapes) {
    $id = Get-IdStr $t; $hid = Resolve-HostId $t; $hn = Resolve-HostName $t
    # Tape servers may not expose their host; the managed server of the same name is then the host,
    # so it is not listed a second time as a managed server without a role
    if (-not $hid -and $t.Name -and $serverByName.ContainsKey($t.Name.ToLower())) { $s = $serverByName[$t.Name.ToLower()]; $hid = Get-IdStr $s; $hn = $s.Name }
    if ($hid) { [void]$UsedHosts.Add($hid) }
    Add-Node $id "server" $t.Name "Tape server" @("M") @{ Host = $hn; Description = $t.Description } | Out-Null
}
# Tape libraries: physical devices of a tape server (TapeServerId is the tape server's Id)
foreach ($l in $tapeLibs) {
    $tsId = "$(Get-Prop $l @('TapeServerId', 'TapeServer.Id'))"
    $model = "$(Get-Prop $l @('Model'))"
    Add-Node ("tapelib:" + (Get-IdStr $l)) "server" $l.Name ("Tape library" + $(if ($model) { " · $model" } else { "" })) @() @{
        "Tape server" = $(if ((Test-Node $tsId)) { $Nodes[$tsId].name } else { $null }); Type = "$(Get-Prop $l @('Type'))"
        Drives = @(@($l.Drives) | Where-Object { $_ }).Count; Slots = (Get-Prop $l @("Slots")); State = "$(Get-Prop $l @('State'))"
        Description = $l.Description } | Out-Null
}
# Cloud Connect service providers this VBR uses (drawn with the repositories, as a backup target)
foreach ($c in $cloudProvs) {
    $rs = $c.Resources; if (-not $rs) { $rs = $c.Resource }
    $res = (@(@($rs) | Where-Object { $_ } | ForEach-Object { "$(Get-Prop $_ @('RepositoryName', 'Name'))" }) | Where-Object { $_ }) -join ", "
    $cn = "$(Get-Prop $c @('DNSName', 'Name', 'Address'))"; if (-not $cn) { $cn = "Cloud Connect provider" }
    Add-Node ("cloud:" + (Get-IdStr $c)) "repo" $cn "Cloud Connect service provider" @() @{
        Port = (Get-Prop $c @("Port")); "Cloud repositories" = $res; Description = $c.Description } | Out-Null
}
# SureBackup virtual labs: placed on the ESXi / Hyper-V host VBR deployed them to (Server)
foreach ($v in $vlabs) {
    $srv = Get-Prop $v @("Server", "Host")
    $hn = "$(Get-Prop $v @('Server.Name', 'Host.Name'))"
    if (-not $hn -and $srv) { $hn = "$srv" -replace '\s*\([0-9a-fA-F-]{36}\)$', '' }   # prints as "esx01.corp.local(<id>)"
    $plat = "$(Get-Prop $v @('Platform'))"
    $n = Add-Node ("vlab:" + (Get-IdStr $v)) "server" $v.Name "SureBackup virtual lab" @() @{ Platform = $plat; Description = $v.Description }
    $hid = $null
    $sid = Get-IdStr (Get-Prop $srv @("Id"))
    if ($sid -and (Test-Node $sid)) { $hid = $sid }
    elseif ($hn) { foreach ($x in $Nodes.Values) { if ($x.kind -in @("vi_host", "hv_host") -and $x.name -ieq $hn) { $hid = $x.id; break } } }
    if ($hn) {
        $n["placement"] = [ordered]@{ host = $hn; vm = $null; source = "Virtual lab host (VBR)"; platform = $(if ($plat -match "Hv|Hyper") { "hv" } else { "vi" }) }
        if ($hid) { $n["runsOn"] = $hid }
        $n.details["Runs on"] = $hn
    }
}

# SOBR extent lookup
$extentOf = @{}
foreach ($sb in $sobrs) {
    foreach ($e in @($sb.Extent)) { if ($e) { $extentOf[(Get-IdStr (Get-Prop $e @("Repository", "Id")))] = (Get-IdStr $sb) } }
}

# Get-VBRBackupRepository leaves out SOBR performance extents; add them from the SOBRs
# (object storage extents are drawn from Get-VBRObjectStorageRepository instead)
$repoSeen = @{}
foreach ($x in @($repos) + @($objRepos)) { if ($x) { $repoSeen[(Get-IdStr $x)] = $true } }
foreach ($sb in $sobrs) {
    foreach ($e in @($sb.Extent)) {
        $er = Get-Prop $e @("Repository")
        if ($er -and -not $repoSeen[(Get-IdStr $er)]) { $repoSeen[(Get-IdStr $er)] = $true; $repos += $er }
    }
}

$dedupTypes = "DDBoost|ExaGrid|StoreOnce|Quantum|Infinidat|Fujitsu"
# Object storage (S3, Azure, Veeam Vault, Object First, ...): Get-VBRBackupRepository returns most of them too,
# before Get-VBRObjectStorageRepository, so they are classified here (Python: OBJECT_REPO_TYPES)
$objectTypes = "S3|Azure(Blob|Archive)|Google|IBM|Wasabi|Vault|Snowball|Glacier|SmartObject"
foreach ($r in $repos) {
    $id = Get-IdStr $r; $t = "$($r.Type)"
    $hid = Resolve-HostId $r; if ($hid) { [void]$UsedHosts.Add($hid) }
    $cap = $null; $free = $null
    try { $c = $r.GetContainer(); $cap = $c.CachedTotalSpace.InGigabytes; $free = $c.CachedFreeSpace.InGigabytes } catch { }
    $gw = $null
    try { $gw = (@($r.GetActualGateways()) | ForEach-Object { $_.Name }) -join ", " } catch { }
    if ($t -match "Cifs|Smb|Nfs") { $kind = "repo"; $label = "NAS share · $t"; $badges = @() }
    elseif ($t -match $objectTypes) { $kind = "object"; $label = "Object storage · $t"; $badges = @() }
    elseif ($t -match $dedupTypes) { $kind = "repo"; $label = "Dedup appliance · $t"; $badges = @() }
    else {
        $kind = "repo"; $badges = @("M")
        $label = switch -Regex ($t) { "Hardened" { "Hardened Linux repository" } "^WinLocal$" { "Windows repository" } "^LinuxLocal$" { "Linux repository" } default { "Repository · $t" } }
        $immut = Get-Prop $r @("IsImmutabilityEnabled", "ImmutabilityEnabled")
        if ($immut -eq $true -and $label -notmatch "Hardened") { $label += " (immutable)" }
    }
    $n = Add-Node $id $kind $r.Name $label $badges @{
        Type = $t; Host = (Resolve-HostName $r); Path = (Get-Prop $r @("FriendlyPath", "Path")); Gateway = $gw
        Capacity = (Format-GB $cap); Free = (Format-GB $free); Description = $r.Description }
    if ($cap) { $n["usage"] = [math]::Round(1 - ([double]$free / [double]$cap), 3) }
}
foreach ($a in $abrRepos) {
    $hid = Get-IdStr (Get-Prop $a @("Server")); if ($hid) { [void]$UsedHosts.Add($hid) }
    $path = (@("$($a.ZFSPool)", "$($a.MountPath)") | Where-Object { $_ }) -join "/"
    Add-Node (Get-IdStr $a) "repo" $a.Name "Application Backup Repository" @("M") @{
        Type = "ApplicationBackupRepository"; Host = (Get-Prop $a @("Server.Name")); Path = $path
        "Retention (days)" = $a.RetentionDays; Description = $a.Description } | Out-Null
}
foreach ($o in $objRepos) {
    $id = Get-IdStr $o
    Add-Node $id "object" $o.Name "Object storage · $($o.Type)" @() @{
        Type = "$($o.Type)"; Bucket = (Get-Prop $o @("AmazonBucket.Name", "Bucket.Name", "Container.Name", "BucketName")); Description = $o.Description } | Out-Null
    # Connection mode (Direct, or through gateway servers) and the gateway servers; GetActualGateways() above
    # does not cover repositories that only Get-VBRObjectStorageRepository returns (Veeam Vault)
    $nd = $Nodes[$id]
    if ("$($o.ConnectionType)") { $nd.details["Connection mode"] = "$($o.ConnectionType)" }
    $gws = @(@($o.GatewayServer) | Where-Object { $_ } | ForEach-Object { $_.Name })
    if ($gws.Count -and -not $nd.details["Gateway"]) { $nd.details["Gateway"] = $gws -join ", " }
}
foreach ($sb in $sobrs) {
    $sid = Get-IdStr $sb
    $ext = @($sb.Extent | Where-Object { $_ })
    $extIds = @($ext | ForEach-Object { Get-IdStr (Get-Prop $_ @("Repository", "Id")) })
    $capExt = @(Get-Prop $sb @("CapacityExtents", "CapacityExtent")) | Where-Object { $_ }
    $archExt = @(Get-Prop $sb @("ArchiveExtent")) | Where-Object { $_ }
    $capNames = ($capExt | ForEach-Object { Get-Prop $_ @("Repository.Name", "Name") }) -join ", "
    $n = Add-Node $sid "sobr" $sb.Name "Scale-out repository · $($ext.Count) extents" @() @{
        "Performance tier" = (($ext | ForEach-Object { Get-Prop $_ @("Repository.Name", "Name") }) -join ", ")
        "Capacity tier" = $(if ($capNames) { $capNames } elseif ($sb.EnableCapacityTier) { "Enabled" } else { "—" })
        "Archive tier" = $(if ($archExt) { (($archExt | ForEach-Object { Get-Prop $_ @("Repository.Name", "Name") }) -join ", ") } else { "—" })
        Description = $sb.Description }
    $n["extents"] = $extIds
    foreach ($e in $extIds) { if ((Test-Node $e)) { $Nodes[$e]["inSobr"] = $sid; $Nodes[$e].details["SOBR extent of"] = $sb.Name } }
    # Capacity / archive tier object storage, for the report's SOBR view; capacity tier: SOBR -> object (offload)
    $capIds = @(); $archIds = @()
    foreach ($ce in $capExt) { $cid = Get-IdStr (Get-Prop $ce @("Repository", "Id")); if ((Test-Node $cid)) { $capIds += $cid; Add-Link $sid $cid "Capacity tier offload" "copy" } }
    foreach ($ae in $archExt) { $aid = Get-IdStr (Get-Prop $ae @("Repository", "Id")); if ((Test-Node $aid)) { $archIds += $aid } }
    if ($capIds.Count) { $n["capacity"] = $capIds }
    if ($archIds.Count) { $n["archive"] = $archIds }
}

foreach ($pg in $pgs) {
    $id = Get-IdStr $pg
    $count = $null; try { $count = @(Get-VBRDiscoveredComputer -ProtectionGroup $pg).Count } catch { }
    Add-Node $id "agent" $pg.Name "Veeam Agent · $(Get-Prop $pg @('Container.Type', 'Type'))" @("A") @{
        Type = (Get-Prop $pg @("Container.Type", "Type")); Computers = $count; Description = $pg.Description } | Out-Null
}

# ---------------------------------------------------------------------------
# Jobs -> data flow
# ---------------------------------------------------------------------------

function Resolve-SourceNode([string]$HostName, [string]$Platform) {
    if (-not $HostName) { return $null }
    $s = $serverByName[$HostName.ToLower()]
    if ($s -and (Test-Node (Get-IdStr $s))) { return Get-IdStr $s }
    $nid = "src:${Platform}:$($HostName.ToLower())"
    if ($Platform -eq "hv") { Add-Node $nid "hv_host" $HostName "Source host (not in managed servers)" @("M") | Out-Null }
    else { Add-Node $nid "vi_host" $HostName "Source host (not in managed servers)" | Out-Null }
    return $nid
}

# One row of a job's protected-object list (shown when the job is expanded in the report)
function New-JobObject([string]$Name, [string]$Type, [string]$Location = "", [string]$Size = "", [bool]$Excluded = $false) {
    return [ordered]@{ name = $Name; type = $Type; location = $Location; size = $Size; excluded = $Excluded }
}

$JobRows = New-Object System.Collections.Generic.List[object]
$jobRepo = @{}   # job id -> repo id (used to find backup copy sources)
# These jobs are handled by their own cmdlets; skip them in Get-VBRJob to avoid duplicates
$handledElsewhere = New-Object System.Collections.Generic.HashSet[string]
foreach ($x in @($copyJobs) + @($agentJobs) + @($nasJobs) + @($entraJobs) + @($entraLogJobs) + @($nasCopyJobs) + @($sbJobs) + @($tapeJobs) + @($cdpPolicies)) { if ($x) { [void]$handledElsewhere.Add((Get-IdStr $x)) } }

foreach ($j in $jobs) {
    $jid = Get-IdStr $j
    $type = "$($j.JobType)"; $plat = "$(Get-Prop $j @('BackupPlatform.Platform', 'BackupPlatform'))"; $typeStr = "$($j.TypeToString)"
    $all = "$type $plat $typeStr"
    $repo = "$(Get-Prop $j @('Info.TargetRepositoryId', 'TargetRepositoryId'))"
    try { if (-not $repo) { $repo = Get-IdStr $j.GetTargetRepository() } } catch { }
    $jobRepo[$jid] = $repo
    if ($handledElsewhere.Contains($jid)) { continue }
    $disabled = (Get-Prop $j @("IsScheduleEnabled", "Info.IsScheduleEnabled")) -eq $false
    $label = $j.Name + $(if ($disabled) { " (disabled)" } else { "" })

    $hosts = New-Object System.Collections.Generic.HashSet[string]
    $objs = @(); try { $objs = @(Get-VBRJobObject -Job $j) } catch { }
    # Only the objects set in the job: ExtendedChild entries are VMs VBR expanded itself (e.g. replica mappings)
    $objs = @($objs | Where-Object { "$($_.Type)" -in @("", "Include", "Exclude") })
    foreach ($o in $objs) {
        $h = Get-Prop $o @("Object.Host.Name", "Host.Name")
        if (-not $h -and $o.Location) { $h = ($o.Location -split '[\\/]')[0] }
        if ($h) { [void]$hosts.Add($h) }
    }
    $sel = @(); try { $sel = @($j.GetProxy() | ForEach-Object { Get-IdStr $_ } | Where-Object { (Test-Node $_) }) } catch { }
    $auto = Get-Prop $j @("Options.JobOptions.SourceProxyAutoDetect")
    if ($auto -eq $true) { $sel = @() }
    $jobObjs = @($objs | ForEach-Object {
        # "0 B" means no estimate (plug-in platform VMs report no size): leave it empty
        $size = "$(Get-Prop $_ @('ApproxSizeString'))"; if ($size -match '^0(\.0+)?\s*[KMGTP]?B$') { $size = "" }
        New-JobObject "$($_.Name)" "$(Get-Prop $_ @('TypeDisplayName', 'Object.ViType', 'Object.Type'))" "$($_.Location)" `
            $size ("$($_.Type)" -eq "Exclude") })

    $JobRows.Add([ordered]@{ name = $j.Name; type = $(if ($typeStr) { $typeStr } else { $type }); disabled = $disabled
        repository = $(if ((Test-Node $repo)) { $Nodes[$repo].name } else { $null }); sources = @($hosts)
        proxies = $(if ($sel.Count) { ($sel | ForEach-Object { $Nodes[$_].name }) -join ", " } else { "Automatic" })
        objects = $jobObjs })

    if ($all -match "Copy|BackupSync|SimpleBackupCopy") {
        $srcRepos = @()
        foreach ($lj in @(Get-Prop $j @("LinkedJobIds"))) { if ($lj) { $srcRepos += $jobRepo["$lj"] } }
        foreach ($lr in @(Get-Prop $j @("LinkedRepositoryIds"))) { if ($lr) { $srcRepos += "$lr" } }
        foreach ($sr in $srcRepos) { Add-Link $sr $repo $label "copy" }
        continue
    }
    if ($all -match "Replica") {
        $tgt = "$(Get-Prop $j @('Info.TargetHostId', 'TargetHostId'))"
        if ($all -match "Hv|HyperV") {
            # Hyper-V: off-host proxies when the job selects them, else the hosts' on-host proxies (host to host)
            foreach ($h in $hosts) {
                $src = Resolve-SourceNode $h "hv"
                if ($sel.Count) { foreach ($p in $sel) { Add-Link $src $p $label "data" } } else { Add-Link $src $tgt $label "copy" }
            }
            foreach ($p in $sel) { Add-Link $p $tgt $label "copy" }
            continue
        }
        $px = if ($sel.Count) { $sel } else { $proxyByType.ViProxy }
        foreach ($h in $hosts) { $src = Resolve-SourceNode $h "vi"; foreach ($p in $px) { Add-Link $src $p $label "auto" } }
        foreach ($p in $px) { Add-Link $p $tgt $label "copy" }
        continue
    }
    if (-not (Test-Node $repo)) { continue }
    # Plug-in platform jobs (checked before Hyper-V: "AHV" would match "Hv"). Their proxies are not
    # readable, so the source links straight to the repository. A source that is not a registered
    # plug-in host (e.g. a cluster name) gets inferred links from every host of that platform.
    $jobPlat = if ($typeStr -match "Proxmox") { "Proxmox VE" } elseif ($typeStr -match "Nutanix|AHV") { "Nutanix AHV" }
               elseif ($typeStr -match "Morpheus") { "HPE Morpheus VME" } elseif ($type -match "VmbApi") { "Plug-in platform" } else { $null }
    if ($jobPlat) {
        $platHosts = @($Nodes.Values | Where-Object { $_.kind -eq "ext_host" -and $_.details["Platform"] -eq $jobPlat })
        foreach ($h in $hosts) {
            $hit = @($platHosts | Where-Object { $_.name -ieq $h })
            if ($hit.Count) { foreach ($x in $hit) { Add-Link $x.id $repo $label "auto" } }
            else { foreach ($x in $platHosts) { Add-Link $x.id $repo $label "inferred" } }
        }
        continue
    }
    if ($all -match "HyperV|Hv") {
        foreach ($h in $hosts) {
            $src = Resolve-SourceNode $h "hv"
            if ($sel.Count) { foreach ($p in $sel) { Add-Link $src $p $label; Add-Link $p $repo $label } }
            else { Add-Link $src $repo $label }   # on-host proxy
        }
    } elseif ($all -match "VMware|Vmware|Vsphere|Vcd") {
        $px = if ($sel.Count) { $sel } else { $proxyByType.ViProxy }
        $k = if ($sel.Count) { "data" } else { "auto" }
        foreach ($h in $hosts) {
            $src = Resolve-SourceNode $h "vi"
            if ($px.Count) { foreach ($p in $px) { Add-Link $src $p $label $k } } else { Add-Link $src $repo $label }
        }
        foreach ($p in $px) { Add-Link $p $repo $label $k }
    } elseif ($all -match "EndPoint|Agent|EpAgent") {
        Add-Node "agents" "agent" "Veeam Agents" "Physical / virtual servers" @("A") | Out-Null
        Add-Link "agents" $repo $label
    }
}

# A job's repository that no repository cmdlet returned is added from the job itself: Veeam Vault archive
# repositories are in neither Get-VBRObjectStorageRepository nor Get-VBRArchiveObjectStorageRepository
function Add-JobRepoNode($r) {
    $id = Get-IdStr $r
    if (-not $id -or (Test-Node $id) -or -not "$(Get-Prop $r @('Name'))") { return $id }
    $t = "$(Get-Prop $r @('Type'))"
    if ($t -match $objectTypes -or "$(Get-Prop $r @('Group'))" -match "Archive") {
        Add-Node $id "object" $r.Name "Object storage · $t" @() @{ Type = $t; Description = $r.Description } | Out-Null
    } else {
        Add-Node $id "repo" $r.Name "Repository · $t" @() @{ Type = $t; Description = $r.Description } | Out-Null
    }
    return $id
}

# Agent jobs (v12+ cmdlet). Policies the agent manages keep their repository in DestinationOptions
foreach ($a in $agentJobs) {
    $repo = Add-JobRepoNode (Get-Prop $a @("BackupRepository", "TargetRepository", "DestinationOptions.BackupRepository"))
    $enabled = Get-Prop $a @("JobEnabled", "IsEnabled")
    $label = $a.Name + $(if ($enabled -eq $false) { " (disabled)" } else { "" })
    $pgIds = @(@($a.BackupObject) | ForEach-Object { Get-IdStr (Get-Prop $_ @("Container", "ProtectionGroup")); Get-IdStr $_ } |
               Where-Object { $_ -and (Test-Node $_) -and $Nodes[$_].kind -eq "agent" })
    if (-not $pgIds.Count) { Add-Node "agents" "agent" "Veeam Agents" "Physical / virtual servers" @("A") | Out-Null; $pgIds = @("agents") }
    foreach ($pg in $pgIds) { Add-Link $pg $repo $label }
    $JobRows.Add([ordered]@{ name = $a.Name; type = "Agent backup ($($a.OSPlatform), $($a.Mode))"; disabled = ($enabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null })
        sources = @($pgIds | ForEach-Object { $Nodes[$_].name }); proxies = "—"
        objects = @(@($a.BackupObject) | Where-Object { $_ } | ForEach-Object {
            New-JobObject "$($_.Name)" "Protection group" "$(Get-Prop $_ @('Container.Type', 'Container'))" }) })
}

# Backup copy jobs (v12+ cmdlet)
foreach ($c in $copyJobs) {
    $tgt = Get-IdStr (Get-Prop $c @("TargetRepository", "Target.Repository", "Repository", "BackupRepository"))
    $srcRepos = @()
    foreach ($sj in @($c.BackupJob)) { if ($sj) { $srcRepos += $jobRepo[(Get-IdStr $sj)] } }
    foreach ($sr in @(Get-Prop $c @("SourceRepository", "Repository"))) {
        if (-not $sr -or (Get-IdStr $sr) -eq $tgt) { continue }
        $sid = Get-IdStr $sr
        # An Application Backup Repository appears here as its virtual repository (another id): match it by name
        if (-not (Test-Node $sid)) {
            $hit = @($Nodes.Values | Where-Object { $_.details["Type"] -eq "ApplicationBackupRepository" -and $_.name -eq "$($sr.Name)" })
            if ($hit.Count -eq 1) { $sid = $hit[0].id }
        }
        $srcRepos += $sid
    }
    foreach ($sr in $srcRepos) { if ($sr) { Add-Link $sr $tgt $c.Name "copy" } }
    $JobRows.Add([ordered]@{ name = $c.Name; type = "Backup copy ($($c.Mode))"; disabled = ($c.JobEnabled -eq $false)
        repository = $(if ((Test-Node "$tgt")) { $Nodes["$tgt"].name } else { $null })
        sources = @(@($c.BackupJob) + @(Get-Prop $c @("SourceRepository")) | Where-Object { $_ } | ForEach-Object { $_.Name }); proxies = "—"
        objects = @(@(@($c.BackupJob) | Where-Object { $_ } | ForEach-Object { New-JobObject "$($_.Name)" "Job" }) +
                    @(@(Get-Prop $c @("SourceRepository")) | Where-Object { $_ } | ForEach-Object { New-JobObject "$($_.Name)" "Repository" })) })
}

# File share / NAS backup. Get-VBRUnstructuredBackupJob also returns file backup copies and Entra ID
# audit log backups; those are told apart by their own cmdlets (or the copy's class name)
$idSet = { param($xs) $h = New-Object System.Collections.Generic.HashSet[string]; foreach ($x in $xs) { if ($x) { [void]$h.Add((Get-IdStr $x)) } }; , $h }
$entraLogIds = & $idSet $entraLogJobs
$nasCopyIds = & $idSet $nasCopyJobs
$nasRepo = @{}
foreach ($n in @($nasJobs) + @($entraLogJobs) + @($nasCopyJobs)) {
    # File backup copy jobs (Get-VBRNASBackupCopyJob) only have TargetRepositoryId
    if ($n) { $nasRepo[(Get-IdStr $n)] = Add-JobRepoNode (Get-Prop $n @("ShortTermBackupRepository", "BackupRepository", "StorageRepository",
                                                                          "TargetRepository", "TargetRepositoryId", "Repository")) }
}
$nasSeen = New-Object System.Collections.Generic.HashSet[string]
foreach ($n in @($nasJobs) + @($entraLogJobs) + @($nasCopyJobs)) {
    if (-not $n) { continue }
    $nid = Get-IdStr $n
    if (-not $nasSeen.Add($nid)) { continue }
    $repo = $nasRepo[$nid]
    $enabled = Get-Prop $n @("JobEnabled", "IsEnabled", "Enabled")
    if ($entraLogIds.Contains($nid)) {
        $JobRows.Add([ordered]@{ name = $n.Name; type = "Entra ID audit log backup"; disabled = ($enabled -eq $false)
            repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null }); sources = @(); proxies = "—"; objects = @() })
        continue
    }
    if ($nasCopyIds.Contains($nid) -or "$($n.GetType().Name)" -match "Copy") {
        # Get-VBRNASBackupCopyJob (v13) gives the source job's ID only, in LinkedJobIds
        $src = @(Get-Prop $n @("BackupJob", "SourceJob", "PrimaryJob", "SourceBackupJob", "Job", "LinkedJobIds"))[0]
        $srcName = "$(Get-Prop $src @('Name'))"
        $sid = Get-IdStr $src
        if (-not $srcName -and $sid) { $srcName = "$(@(@($nasJobs) | Where-Object { $_ -and (Get-IdStr $_) -eq $sid })[0].Name)" }
        $sr = $(if ($sid) { $nasRepo[$sid] } else { $null })
        if ($sr) { Add-Link $sr $repo $n.Name "copy" }
        $JobRows.Add([ordered]@{ name = $n.Name; type = "File backup copy"; disabled = ($enabled -eq $false)
            repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null })
            sources = @($srcName | Where-Object { $_ }); proxies = "—"
            objects = @($srcName | Where-Object { $_ } | ForEach-Object { New-JobObject $_ "Job" }) })
        continue
    }
    foreach ($p in $proxyByType.GeneralPurposeProxy) { Add-Link $p $repo $n.Name "auto" }
    # Each share or bucket, then its include / exclude masks (VBR: File masks; buckets also have tag masks)
    $nasObjs = @(foreach ($b in @($n.BackupObject)) {
        if (-not $b) { continue }
        $path = "$(Get-Prop $b @('Path', 'Container', 'Name'))"
        $srv = ""; try { $srv = $b.Server.GetType().Name } catch { }
        $kind = switch -Regex ($srv) { 'SMB' { "SMB share" } 'NFS' { "NFS share" } 'ObjectStorage|S3|Azure' { "Object storage" } default { "File share" } }
        if ($kind -eq "Object storage") {
            # "<bucket>/<folder>", as Python shows it (Path holds the folder only)
            $bucket = "$(Get-Prop $b @('Container.Name', 'Bucket.Name', 'BucketName', 'ContainerName', 'Container', 'Bucket'))".Trim("/")
            $path = $path.Trim("/")
            if ($bucket -and $bucket -notmatch '^Veeam\.' -and $path -ne $bucket -and -not $path.StartsWith("$bucket/")) {
                $path = (@($bucket, $path) | Where-Object { $_ }) -join "/"
            }
        } elseif ($path.Length -gt 3) { $path = $path.TrimEnd("\", "/") }   # no trailing separator (keeps "C:\")
        New-JobObject $path $kind
        foreach ($mk in @(@("InclusionMask", "File mask", $false), @("InclusionPathMask", "File mask", $false), @("ExclusionMask", "File mask", $true),
                          @("ExclusionPathMask", "File mask", $true), @("InclusionTagMask", "Tag mask", $false), @("ExclusionTagMask", "Tag mask", $true))) {
            foreach ($m in @(Get-Prop $b @($mk[0]))) { if ($m) { New-JobObject "$m" $mk[1] $path "" $mk[2] } }
        }
    })
    $JobRows.Add([ordered]@{ name = $n.Name; type = "File backup"; disabled = ($enabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null }); sources = @(); proxies = "Automatic"
        objects = $nasObjs })
}

# Entra ID tenant backup and SureBackup: no repository or proxy of their own to draw
foreach ($x in $entraJobs) {
    $enabled = Get-Prop $x @("JobEnabled", "IsEnabled", "Enabled")
    $JobRows.Add([ordered]@{ name = $x.Name; type = "Entra ID backup"; disabled = ($enabled -eq $false); repository = $null
        sources = @(); proxies = "—"; objects = @() })
}
foreach ($x in $sbJobs) {
    $enabled = Get-Prop $x @("JobEnabled", "IsEnabled", "Enabled")
    $lj = $x.LinkedJob; if (-not $lj) { $lj = $x.LinkedJobs }
    $linked = @(@($lj) | Where-Object { $_ } | ForEach-Object { "$(Get-Prop $_ @('Job.Name', 'Name'))" } | Where-Object { $_ })
    # A SureBackup job with a virtual lab (and usually an application group); without one it is a content scan
    $vl = $x.PSObject.Properties["VirtualLab"]
    $vlName = if ($vl -and $vl.Value) { "$(Get-Prop $vl.Value @('Name'))" } else { "" }
    if (-not $vlName -and $vl -and $vl.Value) { $vlName = "$($vl.Value)" }
    $ag = Get-Prop $x @("ApplicationGroup")
    $appGroup = "$(Get-Prop $ag @('Name'))"; if (-not $appGroup -and $ag) { $appGroup = "$ag" }
    $agVms = (@(@(Get-Prop $ag @("VM")) | Where-Object { $_ } | ForEach-Object { $vn = Get-Prop $_ @('Name'); if ($vn) { "$vn" } else { "$_" } }) | Where-Object { $_ }) -join ", "
    $JobRows.Add([ordered]@{ name = $x.Name; type = $(if ($vlName) { "SureBackup" } else { "SureBackup (content scan)" })
        disabled = ($enabled -eq $false); repository = $null; sources = $linked; proxies = "—"
        objects = @(@($linked | ForEach-Object { New-JobObject $_ "Job" }) + @($(if ($appGroup) { New-JobObject $appGroup "Application group" $agVms })) +
                    @($(if ($vlName) { New-JobObject $vlName "Virtual lab" }))) })
}

# Tape jobs: the target is a media pool (shown as the repository); sources are jobs or file shares
foreach ($x in $tapeJobs) {
    $tt = "$($x.Type)"
    $type = switch -Regex ($tt) { '^BackupToTape$' { "Backup to tape" } '^FileToTape$' { "File to tape" } default { "Tape ($tt)" } }
    $srcs = @(@($x.Object) | Where-Object { $_ } | ForEach-Object { "$(Get-Prop $_ @('Name', 'Path'))" } | Where-Object { $_ })
    $JobRows.Add([ordered]@{ name = $x.Name; type = $type; disabled = ((Get-Prop $x @("Enabled", "JobEnabled")) -eq $false)
        repository = "$(Get-Prop $x @('Target.Name', 'Target'))"; sources = $srcs; proxies = "—"
        objects = @($srcs | ForEach-Object { New-JobObject $_ $(if ($tt -match "File") { "File share" } else { "Job" }) }) })
}

# CDP policies (VMware CDP): source hosts -> CDP proxies -> target host, as replicas are drawn
foreach ($x in $cdpPolicies) {
    $enabled = Get-Prop $x @("IsEnabled", "Enabled", "JobEnabled")
    $label = $x.Name + $(if ($enabled -eq $false) { " (disabled)" } else { "" })
    $objs = @(@(Get-Prop $x @("Entity", "Objects", "Object", "BackupObject")) | Where-Object { $_ })
    $hosts = New-Object System.Collections.Generic.HashSet[string]
    foreach ($o in $objs) { $h = "$(Get-Prop $o @('Host.Name', 'Object.Host.Name', 'HostName'))"; if ($h) { [void]$hosts.Add($h) } }
    $tgt = Get-IdStr (Get-Prop $x @("Server", "TargetHost", "Host"))
    $repo = Get-IdStr (Get-Prop $x @("MetadataRepository", "BackupRepository"))
    $px = @($proxyByType.CdpProxy)
    foreach ($h in $hosts) { $src = Resolve-SourceNode $h "vi"; foreach ($p in $px) { Add-Link $src $p $label "auto" } }
    foreach ($p in $px) { Add-Link $p $tgt $label "copy" }
    $JobRows.Add([ordered]@{ name = $x.Name; type = "CDP policy"; disabled = ($enabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null }); sources = @($hosts); proxies = "Automatic"
        objects = @($objs | ForEach-Object { New-JobObject "$(Get-Prop $_ @('Name'))" "Virtual machine" "$(Get-Prop $_ @('Host.Name', 'Object.Host.Name', 'HostName'))" }) })
}

# Cloud Director replication jobs that Get-VBRJob does not return (listed only)
$jobIds = & $idSet $jobs
foreach ($x in $vcdReplicas) {
    if (-not $x -or $jobIds.Contains((Get-IdStr $x))) { continue }
    $enabled = Get-Prop $x @("IsScheduleEnabled", "IsEnabled", "Enabled", "JobEnabled")
    $JobRows.Add([ordered]@{ name = $x.Name; type = "Cloud Director Replication"; disabled = ($enabled -eq $false); repository = $null
        sources = @(); proxies = "—"; objects = @() })
}

# Configuration backup: listed, and its target shown on the backup server (the diagram has no
# links from the backup server)
foreach ($x in $cfgJobs) {
    $repo = Get-IdStr (Get-Prop $x @("Repository", "BackupRepository", "Target"))
    $enabled = Get-Prop $x @("Enabled", "IsEnabled", "JobEnabled")
    $name = "$($x.Name)"; if (-not $name) { $name = "Backup Configuration Job" }
    if ((Test-Node "$repo")) { $Nodes["vbr"].details["Config backup target"] = $Nodes["$repo"].name }
    $enc = Get-Prop $x @("EncryptionOptions.Enabled", "EncryptionOptions.Enable", "EncryptionOptions")
    if ($enc -is [bool]) { $Nodes["vbr"].details["Config backup encrypted"] = $(if ($enc) { "Yes" } else { "No" }) }
    $JobRows.Add([ordered]@{ name = $name; type = "Configuration backup"; disabled = ($enabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null }); sources = @($vbrName); proxies = "—"; objects = @() })
}

# Retention and encryption of each job. Get-VBRJob objects: BackupStorageOptions (RetainCycles or
# RetainDaysToKeep, by RetentionType). The v12+ cmdlets name these properties differently (agent and Entra ID:
# RetentionPolicy + RetentionType RestoreDays / RestorePoints; file share: ShortTermRetentionPeriod +
# ShortTermRetentionType Daily / Monthly / Yearly), so several names are tried, the job's own cmdlet first,
# then its Get-VBRJob object. Missing values stay empty.
function Get-RetentionText($x) {
    # File share jobs (JobType NasBackup / NasBackupCopy) keep their retention in NasBackupRetentionPolicy; their
    # BackupStorageOptions holds an unused default. A file backup copy job without custom retention carries the source
    # job's value there. Every other Get-VBRJob job has NasBackupRetentionPolicy too, with an unused 28-day default.
    $nrp = $(if ("$(Get-Prop $x @('JobType'))" -match '^Nas') { Get-Prop $x @("Options.NasBackupRetentionPolicy", "NasBackupRetentionPolicy") })
    $bso = Get-Prop $x @("Options.BackupStorageOptions", "BackupStorageOptions")
    if ($nrp -and (Get-Prop $nrp @("ShortTermRetention"))) {
        $n = Get-Prop $nrp @("ShortTermRetention")
        $t = "$(Get-Prop $nrp @('ShortTermRetentionUnit'))"
    } elseif ($bso) {
        $t = "$(Get-Prop $bso @('RetentionType'))"
        $n = $(if ($t -match "Day") { Get-Prop $bso @("RetainDaysToKeep") } else { Get-Prop $bso @("RetainCycles") })
    } else {
        $n = Get-Prop $x @("RetentionPolicy.Quantity", "RetentionPolicy", "RetentionNumber", "RetentionPeriod", "ShortTermRetentionPeriod",
                           "ShortTermBackupRetention", "RestorePointsToKeep", "RestorePointsToKeepNumber")
        $t = "$(Get-Prop $x @('RetentionPolicy.Type', 'RetentionType', 'ShortTermRetentionType', 'RetentionPeriodType'))"
        if (-not $t -and (Get-Prop $x @("RestorePointsToKeep", "RestorePointsToKeepNumber"))) { $t = "RestorePoints" }
    }
    if ("$n" -notmatch '^\d+$' -or [int]"$n" -le 0) { return $null }
    $unit = switch -Regex ($t) { 'Day|Daily' { "day" } 'Week' { "week" } 'Month' { "month" } 'Year' { "year" } 'Cycle|Point' { "restore point" } default { $null } }
    if (-not $unit) { return $null }
    return "$n $unit" + $(if ([int]"$n" -eq 1) { "" } else { "s" })
}
function Get-Encrypted($x) {
    $e = Get-Prop $x @("Options.BackupStorageOptions.StorageEncryptionEnabled", "BackupStorageOptions.StorageEncryptionEnabled",
                       "StorageOptions.EncryptionEnabled", "StorageOptions.Encryption", "EncryptionOptions.Enabled", "EncryptionOptions.Enable",
                       "EncryptionOptions", "EncryptionEnabled")
    if ($e -is [bool]) { return $e }
    return $null
}
$settingsSrc = @{}   # job name -> objects to read, the job's own cmdlet first
foreach ($x in @($agentJobs) + @($copyJobs) + @($nasJobs) + @($entraJobs) + @($entraLogJobs) + @($nasCopyJobs) + @($cdpPolicies) +
               @($vcdReplicas) + @($jobs)) {
    if ($x -and $x.Name) { if (-not $settingsSrc.ContainsKey($x.Name)) { $settingsSrc[$x.Name] = @() }; $settingsSrc[$x.Name] += , $x }
}
foreach ($r in $JobRows) {
    $srcs = $(if ($r.type -eq "Configuration backup") { @($cfgJobs) } else { @($settingsSrc[$r.name]) })
    $ret = $null; $enc = $null
    foreach ($x in $srcs) {
        if (-not $x) { continue }
        if (-not $ret) { $ret = Get-RetentionText $x }
        if ($null -eq $enc) { $enc = Get-Encrypted $x }
    }
    # Replicas keep VMs, not backup files: no encryption setting (REST has none for them either)
    if ($r.type -match "Replica|Replication|CDP") { $enc = $null }
    $r["retention"] = $ret; $r["encrypted"] = $enc
}

# Backups (as the VBR console's Backups view lists them) and, per job, restore points, last backup and
# size on disk. Per backup and VM: the restore points, the newest one and the size of the backup files.
# - Plug-in platform backups (JobType VmbApiPolicyTempJob: Nutanix AHV, Proxmox VE, HPE Morpheus VME):
#   Get-VBRRestorePoint refuses them, so their per-VM child backups and backup files are read with
#   FindChildBackups() and GetAllChildrenStorages() (one file per restore point)
# - Other backups: Get-VBRRestorePoint, with the size from GetStorage()
# These methods are not supported by Veeam; when they fail the values stay empty. As in the VBR console,
# each object of a backup is its own row (one VM can be several objects, for example after it was registered
# again), backups without restore points are not listed, and job totals leave out backups kept only as
# storage snapshots. Get-VBRBackup can also return child backups: a backup whose restore points are all in
# another one is left out.
$idByName = @{}
foreach ($x in @($jobs) + @($agentJobs) + @($copyJobs) + @($nasJobs) + @($entraJobs) + @($entraLogJobs) + @($nasCopyJobs) +
               @($sbJobs) + @($tapeJobs) + @($cdpPolicies) + @($vcdReplicas)) { if ($x -and $x.Name) { $idByName[$x.Name] = Get-IdStr $x } }
$nameById = @{}; foreach ($k in $idByName.Keys) { $nameById[$idByName[$k]] = $k }
$typeByJob = @{}; foreach ($r in $JobRows) { $i = $idByName[$r.name]; if ($i) { $typeByJob["$i"] = "$($r.type)" } }
$rpFailed = [ordered]@{}   # backup id -> name (only backups of jobs in the report)
$rpError = $null
$childIds = @{}
$vmsByBackup = [ordered]@{}   # backup id -> object key -> @{ Name; Points; First; Last; Files }
$fmtTime = { param($t) if ($t) { ([datetime]$t).ToString("yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture) } else { $null } }
function Add-BackupPoint($Vms, [string]$Key, [string]$Vm, [string]$PointId, $Time, $File) {
    if (-not $Key) { $Key = $Vm }
    if (-not $Vms.Contains($Key)) { $Vms[$Key] = @{ Name = $Vm; Points = @{}; First = $null; Last = $null; Files = @{} } }
    $v = $Vms[$Key]
    $ptId = $(if ($PointId) { $PointId } else { [guid]::NewGuid().ToString() })
    $v.Points[$ptId] = $true
    if ($Time -and (-not $v.Last -or $Time -gt $v.Last)) { $v.Last = $Time }
    # First: the oldest backup file, as the console's creation time (the restore point's time if no file)
    $ft = Get-Prop $File @("CreationTime"); if (-not $ft) { $ft = $Time }
    if ($ft -and (-not $v.First -or $ft -lt $v.First)) { $v.First = $ft }
    $fid = "$(Get-Prop $File @('Id'))"
    if ($fid) { try { $v.Files[$fid] = [int64]$File.Stats.BackupSize } catch { } }
}
function Get-BackupTotals($Vms) {
    $files = @{}; $max = 0; $last = $null
    foreach ($v in $Vms.Values) {
        foreach ($k in $v.Files.Keys) { $files[$k] = $v.Files[$k] }
        if ($v.Points.Count -gt $max) { $max = $v.Points.Count }
        if ($v.Last -and (-not $last -or $v.Last -gt $last)) { $last = $v.Last }
    }
    $size = $null; if ($files.Count) { $size = [int64]0; foreach ($x in $files.Values) { $size += $x } }
    return [ordered]@{ restorePoints = $(if ($max) { $max } else { $null }); lastBackup = (& $fmtTime $last); onDisk = $size }
}
foreach ($b in @($backups | Where-Object { $_ -and "$($_.JobType)" -eq "VmbApiPolicyTempJob" })) {
    $vms = [ordered]@{}; $vmsByBackup["$($b.Id)"] = $vms
    try { $children = @($b.FindChildBackups()); $files = @($b.GetAllChildrenStorages()) }
    catch { if ($typeByJob["$(Get-Prop $b @('JobId'))"]) { $rpFailed["$($b.Id)"] = "$($b.Name)"; if (-not $rpError) { $rpError = $_.Exception.Message } }; continue }
    $vmOf = @{}
    foreach ($c in $children) {
        if (-not $c) { continue }
        $cid = "$($c.Id)"; $childIds[$cid] = $true
        # A child backup is named "<VM> Backup" or "<VM> Backup <n>"
        $vn = "$(Get-Prop $c @('VmName', 'ObjectName'))"; if (-not $vn) { $vn = "$($c.Name)" -replace ' Backup( \d+)?$', '' }
        $vmOf[$cid] = $vn
    }
    foreach ($f in $files) {
        if (-not $f) { continue }
        $bid = "$($f.BackupId)"
        Add-BackupPoint $vms $bid $(if ($vmOf.ContainsKey($bid)) { $vmOf[$bid] } else { $bid }) "$($f.Id)" (Get-Prop $f @("CreationTime")) $f
    }
}
foreach ($b in $backups) {
    if (-not $b -or "$($b.JobType)" -eq "VmbApiPolicyTempJob" -or $childIds.ContainsKey("$($b.Id)")) { continue }
    $vms = [ordered]@{}; $vmsByBackup["$($b.Id)"] = $vms
    $rps = @()
    try { $rps = @(Get-VBRRestorePoint -Backup $b) }
    catch { if ($typeByJob["$(Get-Prop $b @('JobId'))"]) { $rpFailed["$($b.Id)"] = "$($b.Name)"; if (-not $rpError) { $rpError = $_.Exception.Message } }; continue }
    foreach ($rp in $rps) {
        $f = $null; try { $f = $rp.GetStorage() } catch { }
        Add-BackupPoint $vms "$(Get-Prop $rp @('ObjectId'))" "$(Get-Prop $rp @('Name', 'VmName'))" "$(Get-Prop $rp @('Id'))" (Get-Prop $rp @("CreationTime")) $f
    }
}
# Child backups returned on their own (a plug-in child has no children of its own to read)
foreach ($c in @($childIds.Keys)) { $rpFailed.Remove($c); $vmsByBackup.Remove($c) }
if ($rpFailed.Count) {
    $script:Warnings.Add("Restore points of $($rpFailed.Count) backups could not be read: $((@($rpFailed.Values) | Sort-Object -Unique) -join ', '). Error: $rpError")
}
# Child backups returned on their own: all their restore points are in another backup
$pointsOf = @{}
foreach ($k in $vmsByBackup.Keys) { $h = @{}; foreach ($v in $vmsByBackup[$k].Values) { foreach ($p in $v.Points.Keys) { $h[$p] = $true } }; $pointsOf[$k] = $h }
$order = @($vmsByBackup.Keys); $dropped = @{}
for ($i = 0; $i -lt $order.Count; $i++) {
    $bp = $pointsOf[$order[$i]]; if (-not $bp.Count) { continue }
    for ($j = 0; $j -lt $order.Count; $j++) {
        if ($i -eq $j -or $dropped[$order[$j]]) { continue }
        $ap = $pointsOf[$order[$j]]
        if ($ap.Count -lt $bp.Count -or ($ap.Count -eq $bp.Count -and $j -gt $i)) { continue }
        $all = $true; foreach ($p in $bp.Keys) { if (-not $ap.ContainsKey($p)) { $all = $false; break } }
        if ($all) { $dropped[$order[$i]] = $true; break }
    }
}
$backupById = @{}; foreach ($b in $backups) { if ($b) { $backupById["$($b.Id)"] = $b } }
$BackupRows = New-Object System.Collections.Generic.List[object]
$platformMap = @{ vmware = "VMware"; hyperv = "Hyper-V"; vcd = "VMware Cloud Director"; clouddirector = "VMware Cloud Director"
    endpoint = "Windows"; windowsphysical = "Windows"; linuxphysical = "Linux"; unixphysical = "Unix"; solarisphysical = "Unix"
    macphysical = "Mac"; nas = "Unstructured data"; unstructureddata = "Unstructured data"; entraid = "Microsoft Entra ID"
    abrbackup = "Application backup repository" }
foreach ($k in $vmsByBackup.Keys) {
    if ($dropped[$k] -or -not $vmsByBackup[$k].Count) { continue }
    $b = $backupById[$k]; $vms = $vmsByBackup[$k]
    # Its job: JobId, or the job of the same name (a backup copy's backups can name another id)
    $jid = "$(Get-Prop $b @('JobId'))"
    if (-not $nameById[$jid] -and $idByName["$($b.Name)"]) { $jid = $idByName["$($b.Name)"] }
    $repoId = "$(Get-Prop $b @('RepositoryId'))"
    $isSnapshot = $repoId -match '^[0-]+$'
    $repo = $(if ((Test-Node $repoId)) { $Nodes[$repoId].name } else { $null })
    if (-not $repo) { try { $repo = "$($b.GetRepository().Name)" } catch { } }
    if (-not $repo -and $isSnapshot) { $repo = "Snapshot" }
    # Platform: the plug-in platform ID, else the platform name
    $pfId = "$(Get-Prop $b @('PlatformId', 'BackupPlatform.PlatformId'))"
    $pf = ("$(Get-Prop $b @('Platform', 'BackupPlatform.Platform'))" -replace '^E(?=[A-Z])', '')
    if ($PluginPlatforms.ContainsKey($pfId)) { $pf = $PluginPlatforms[$pfId] }
    elseif ($platformMap.ContainsKey($pf.ToLower())) { $pf = $platformMap[$pf.ToLower()] }
    elseif ("$($b.JobType)" -eq "VmbApiPolicyTempJob" -or $pf -eq "CustomPlatform") {
        $jt = $typeByJob[$jid]
        $pf = $(if ($jt -match "Nutanix|AHV") { "Nutanix AHV" } elseif ($jt -match "Proxmox") { "Proxmox VE" } elseif ($jt -match "Morpheus") { "HPE Morpheus VME" }
                elseif ($jt -match '^Agent backup \((\w+)') { $Matches[1] }
                elseif ("$($b.JobType)" -match "Copy|BackupSync") { "Image-level" } else { "Plug-in" })
    }
    # Created: the oldest backup file, as the console shows it (CreationTime can be the date of an upgrade)
    $first = $null; foreach ($v in $vms.Values) { if ($v.First -and (-not $first -or $v.First -lt $first)) { $first = $v.First } }
    if (-not $first) { $first = Get-Prop $b @("CreationTime") }
    $row = [ordered]@{ name = "$($b.Name)"; job = $nameById[$jid]; created = (& $fmtTime $first); repository = $repo
        platform = $(if ($pf) { $pf } else { $null }) }
    if ($vms.Count) { $t = Get-BackupTotals $vms; foreach ($x in $t.Keys) { $row[$x] = $t[$x] } }
    $row["objects"] = @($vms.Keys | Sort-Object { "$($vms[$_].Name)".ToLower() }, { $_ } | ForEach-Object {
        $o = [ordered]@{ name = $vms[$_].Name }; $t = Get-BackupTotals @{ $_ = $vms[$_] }; foreach ($x in $t.Keys) { $o[$x] = $t[$x] }; $o })
    $BackupRows.Add($row)
}
$BackupRows = @($BackupRows | Sort-Object { "$($_.name)".ToLower() }, { "$($_.repository)" })

# Last run and result of each job, from its newest session:
# - Get-VBRJob jobs (VMware, Hyper-V, Cloud Director, plug-in platforms, replicas, backup copies):
#   FindLastSession(), which Veeam does not support
# - agent, file share, SureBackup and Entra ID jobs: their own session cmdlets
# - tape jobs and the configuration backup: their LastResult and, when there is one, last run time
$lastByJob = @{}
function Add-LastSession([string]$JobId, $Time, $Result) {
    if (-not $JobId -or -not $Time) { return }
    $cur = $lastByJob[$JobId]
    if (-not $cur -or $Time -gt $cur.Time) { $lastByJob[$JobId] = @{ Time = $Time; Result = "$Result" } }
}
foreach ($j in $jobs) {
    if (-not $j) { continue }
    try { $s = $j.FindLastSession(); if ($s) { Add-LastSession (Get-IdStr $j) (Get-Prop $s @("CreationTime")) (Get-Prop $s @("Result")) } } catch { }
}
foreach ($cmd in @("Get-VBRComputerBackupJobSession", "Get-VBRNASBackupJobSession", "Get-VBRSureBackupSession",
                   "Get-VBREntraIDTenantBackupJobSession", "Get-VBREntraIDLogsBackupJobSession")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { continue }
    $sessions = Invoke-Safe $cmd ([scriptblock]::Create("$cmd -WarningAction SilentlyContinue"))
    foreach ($s in $sessions) {
        if ($s) { Add-LastSession "$(Get-Prop $s @('JobId', 'Job.Id'))" (Get-Prop $s @("CreationTime", "StartTime")) (Get-Prop $s @("Result")) }
    }
}
$resultByJob = @{}
foreach ($x in @($tapeJobs) + @($cfgJobs)) {
    if (-not $x) { continue }
    $key = $(if ($cfgJobs -contains $x) { "cfg" } else { Get-IdStr $x })
    $res = "$(Get-Prop $x @('LastResult'))"; if ($res) { $resultByJob[$key] = $res }
    Add-LastSession $key (Get-Prop $x @("LastRun", "LastRunTime", "LastRunLocal")) $res
}
foreach ($r in $JobRows) {
    $jid = $(if ($r.type -eq "Configuration backup") { "cfg" } else { "$($idByName[$r.name])" })
    $ls = $lastByJob[$jid]
    $res = $(if ($ls) { $ls.Result } else { $resultByJob[$jid] })
    # As in the console: no result without a run time, and N/A for policies the agent manages itself
    $r["lastRun"] = $(if ($ls) { & $fmtTime $ls.Time } else { $null })
    $r["lastResult"] = $(if ($r.type -match "ManagedByAgent") { "N/A" } elseif ($ls -and $res -and $res -ne "None") { $res } else { $null })
}

# Cells PowerShell cannot fill: the report shows "n/a" with a footnote (texts: note_<code> in template.html I18N)
foreach ($r in $JobRows) {
    $na = [ordered]@{}
    if ($r.type -match "^(Backup|File) to tape$" -or $r.type -match "^Tape \(") {
        $na["retention"] = "tapeMediaPool"; $na["encrypted"] = "tapeMediaPool"
        if (-not $r.lastRun) { $na["lastRun"] = "tapeLastRun" }
    } elseif ($r.type -eq "Configuration backup" -and -not $r.lastRun) {
        $na["lastRun"] = "configLastRun"; $na["lastResult"] = "configLastRun"
    } elseif ($r.type -eq "Entra ID backup" -and -not $r.lastRun) {
        $na["lastRun"] = "entraLastRun"; $na["lastResult"] = "entraLastRun"
    }
    if ($na.Count) { $r["unavailable"] = $na }
}

# Re-point links to SOBR extents at the SOBR itself
foreach ($key in @($Links.Keys)) {
    $l = $Links[$key]; $changed = $false
    foreach ($end in "source", "target") {
        $sb = $Nodes[$l[$end]]["inSobr"]
        if ($sb) { $l[$end] = $sb; $changed = $true }
    }
    if ($changed) {
        $Links.Remove($key)
        $nk = "$($l.source)|$($l.target)"
        if ($l.source -ne $l.target -and -not $Links.Contains($nk)) { $Links[$nk] = $l }
    }
}

# VMware sources without job information -> inferred links
# With a vCenter present, ESXi hosts are normally backed up through it, so skip them
$hasOut = @{}; foreach ($l in $Links.Values) { $hasOut[$l.source] = $true }
$hasVc = @($Nodes.Values | Where-Object { $_.kind -eq "vi_host" -and $_.sub -match "vCenter" }).Count -gt 0
foreach ($n in @($Nodes.Values)) {
    if ($hasVc -and $n.sub -match "^ESXi") { continue }
    if ($n.kind -eq "vi_host" -and -not $hasOut[$n.id]) { foreach ($p in $proxyByType.ViProxy) { Add-Link $n.id $p $null "inferred" } }
}

# Other managed servers
foreach ($s in $servers) {
    $id = Get-IdStr $s
    if (-not $UsedHosts.Contains($id) -and -not (Test-Node $id)) {
        Add-Node $id "server" $s.Name "Managed server · $($s.Type)" @() @{ Type = "$($s.Type)"; Description = $s.Description } | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Component placement: which ESXi / Hyper-V host runs the VBR, EM, proxies, repositories, tape ...
# ---------------------------------------------------------------------------

Write-Host "Matching component hosts:"
$placeMap = @{}     # lowercase name / IP -> placement
$placeShort = @{}   # lowercase first label of a name -> placement (weakest match)
function Add-PlaceKey([string]$Key, $Info, [hashtable]$Map = $placeMap) {
    # Entries without a host name (e.g. a VM on a disconnected host) cannot place anything
    if (-not $Key -or -not $Info -or -not $Info.host) { return }
    $k = $Key.Trim().ToLower()
    if ($k -and -not $Map.ContainsKey($k)) { $Map[$k] = $Info }
}
function Add-PlaceKeys([string]$Name, $Info) {
    if (-not $Name) { return }
    Add-PlaceKey $Name $Info
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Name, [ref]$ip)) { Add-PlaceKey ($Name.Split(".")[0]) $Info $placeShort }
}

# 1) Manual CSV map
if ($PlacementCsv) {
    try {
        $rows = @(Import-Csv $PlacementCsv)
        foreach ($r in $rows) { if ($r.Component -and $r.Host) { Add-PlaceKeys $r.Component @{ host = $r.Host; vm = $r.VM; source = "Manual CSV"; platform = "vi" } } }
        Write-Host ("  [OK]   {0,-28} {1}" -f "PlacementCsv", $rows.Count)
    } catch { $script:Warnings.Add("PlacementCsv: $($_.Exception.Message)") }
}

$viSrv = @($servers | Where-Object { "$($_.Type)" -match '^(VC|ESXi?)$' })
$vcOnly = @($viSrv | Where-Object { "$($_.Type)" -eq "VC" })
$viScan = if ($vcOnly.Count) { $vcOnly } else { $viSrv }   # query only the vCenter(s) when present

# Connect to one vCenter. If the login is rejected, ask once more for that vCenter's credentials
# (vCenters often use different accounts); logins from -VCenterCredentialMap are not re-asked.
function Connect-VCenter([string]$Name) {
    $fromMap = $VCenterCredentialMap.ContainsKey($Name)
    $cred = if ($fromMap) { $VCenterCredentialMap[$Name] } else { $VCenterCredential }
    try {
        if ($cred) { return Connect-VIServer $Name -Credential $cred -ErrorAction Stop }
        return Connect-VIServer $Name -ErrorAction Stop
    } catch {
        $badLogin = "$($_.Exception.Message)" -match "incorrect user name or password|InvalidLogin|401"
        if (-not $badLogin -or $fromMap) { throw }
        Write-Host "  Login to $Name failed: incorrect user name or password." -ForegroundColor Yellow
        $gc = @{ Message = "Enter the vCenter credentials for $Name" }
        if ($cred) { $gc.UserName = $cred.UserName } elseif ($VCenterUser) { $gc.UserName = $VCenterUser }
        $retry = Get-Credential @gc
        if (-not $retry) { throw }
        return Connect-VIServer $Name -Credential $retry -ErrorAction Stop
    }
}

# 2) PowerCLI (optional)
if ($UsePowerCLI) {
    if (-not (Get-Module -ListAvailable VMware.VimAutomation.Core)) {
        Write-Host "  [skip] PowerCLI is not installed; using the Veeam inventory instead. To install (as administrator):" -ForegroundColor Yellow
        Write-Host "         Install-Module VCF.PowerCLI -Scope AllUsers      # PowerCLI 9.x (Broadcom)" -ForegroundColor Yellow
        Write-Host "         Install-Module VMware.PowerCLI -Scope AllUsers   # or PowerCLI 13.x" -ForegroundColor Yellow
        Write-Host "         No internet on the VBR server: run Save-Module VCF.PowerCLI -Path D:\pcli on another machine," -ForegroundColor Yellow
        Write-Host "         then copy that folder to C:\Program Files\WindowsPowerShell\Modules on the VBR server" -ForegroundColor Yellow
        $script:Warnings.Add("PowerCLI not installed; component hosts matched via the Veeam inventory (VM names)")
    } else {
    try {
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        # Self-signed cert and CEIP prompts would block the script; disable them for this session only
        try { Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false | Out-Null } catch { }
        $needCred = @($viScan | Where-Object { -not $VCenterCredentialMap.ContainsKey($_.Name) })
        if (-not $VCenterCredential -and $needCred.Count) {
            $vcNames = ($needCred | ForEach-Object { $_.Name }) -join ", "
            Write-Host "  vCenter login for PowerCLI: $vcNames" -ForegroundColor Cyan
            $gc = @{ Message = "Enter the vCenter credentials for $vcNames (a read-only vCenter account is enough)" }
            if ($VCenterUser) { $gc.UserName = $VCenterUser }
            $VCenterCredential = Get-Credential @gc
        }
        foreach ($vc in $viScan) {
            $ci = $null
            try {
                $ci = Connect-VCenter $vc.Name
                $vms = @(Get-VM -Server $ci)
                $noHost = 0
                foreach ($vm in $vms) {
                    if (-not $vm.VMHost -or -not $vm.VMHost.Name) { $noHost++; continue }
                    $info = @{ host = $vm.VMHost.Name; vm = $vm.Name; source = "PowerCLI ($($vc.Name))"; platform = "vi"; ips = @($vm.Guest.IPAddress) }
                    Add-PlaceKeys $vm.Name $info
                    if ($vm.Guest.HostName) { Add-PlaceKeys $vm.Guest.HostName $info }
                    foreach ($ip in @($vm.Guest.IPAddress)) { Add-PlaceKey $ip $info }
                }
                $skipped = if ($noHost) { " ($noHost without a host, skipped)" } else { "" }
                Write-Host ("  [OK]   {0,-28} {1}{2}" -f "PowerCLI $($vc.Name)", $vms.Count, $skipped)
            } catch { $script:Warnings.Add("PowerCLI $($vc.Name): $($_.Exception.Message)") }
            finally { if ($ci) { Disconnect-VIServer $ci -Confirm:$false -ErrorAction SilentlyContinue } }
        }
    } catch { $script:Warnings.Add("PowerCLI could not be loaded: $($_.Exception.Message)") }
    }
}

# 3) Veeam's own vSphere / Hyper-V inventory (matched by VM name)
$hostCluster = @{}  # lowercase ESXi host name -> vSphere cluster (the report groups hosts by cluster)
function Read-Inventory($Srv, [string]$Platform) {
    $ents = @()
    try {
        if ($Platform -eq "vi") { $ents = @(Find-VBRViEntity -Server $Srv -HostsAndClusters -WarningAction SilentlyContinue) }
        else { $ents = @(Find-VBRHvEntity -Server $Srv -WarningAction SilentlyContinue) }
    } catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -match "WMI") {
            $script:Warnings.Add("VBR could not query Hyper-V host $($Srv.Name) (WMI). Check that the host is online and that its credentials in VBR are valid. Details: $msg")
        } elseif ($msg -match "not a cluster|cluster services") {
            $script:Warnings.Add("VBR could not reach the Hyper-V cluster $($Srv.Name). Check that the cluster service is running, or remove the stale cluster from VBR. Details: $msg")
        } else {
            $script:Warnings.Add("Reading the inventory of $($Srv.Name) failed: $msg")
        }
        return
    }
    $hostNames = @{}
    foreach ($e in $ents) { if ("$($e.Type)" -match '^(Host|Esx|Server)') { $hostNames[$e.Name.ToLower()] = $e.Name } }
    # vSphere clusters: a host whose parent path is a cluster's path belongs to that cluster
    $clPaths = @{}
    foreach ($e in $ents) {
        if ("$($e.Type)" -match '^(Cluster|ClusterComputeResource)$' -and $e.Path) { $clPaths["$($e.Path)".TrimEnd('\', '/').ToLower()] = $e.Name }
    }
    foreach ($e in $ents) {
        if ("$($e.Type)" -notmatch '^(Host|Esx)' -or -not $e.Path) { continue }
        $cn = $clPaths[("$($e.Path)".TrimEnd('\', '/') -replace '[\\/][^\\/]*$', '').ToLower()]
        if ($cn) { $hostCluster[$e.Name.ToLower()] = [ordered]@{ name = $cn; vcenter = $Srv.Name } }
    }
    foreach ($h in $servers) { if ("$($h.Type)" -match '^(ESXi?|HvServer)$') { $hostNames[$h.Name.ToLower()] = $h.Name } }
    $n = 0
    foreach ($e in $ents) {
        if ("$($e.Type)" -notmatch '^(Vm|VirtualMachine)$') { continue }
        $segs = @("$($e.Path)" -split '[\\/]' | Where-Object { $_ })
        $h = $null
        foreach ($sg in $segs) { if ($hostNames.ContainsKey($sg.ToLower())) { $h = $hostNames[$sg.ToLower()] } }
        if (-not $h) { $h = Get-Prop $e @("VmHostName", "HostName", "Host.Name") }
        if (-not $h -and "$($Srv.Type)" -match '^(ESXi?|HvServer)$') { $h = $Srv.Name }
        if (-not $h -and $segs.Count -ge 2) { $h = $segs[$segs.Count - 2] }
        if (-not $h) { continue }
        Add-PlaceKeys $e.Name @{ host = $h; vm = $e.Name; source = "Veeam inventory ($($Srv.Name))"; platform = $Platform }
        $n++
    }
    Write-Host ("  [OK]   {0,-28} {1}" -f "Inventory $($Srv.Name)", $n)
}
foreach ($vc in $viScan) { Read-Inventory $vc "vi" }
foreach ($hv in @($servers | Where-Object { "$($_.Type)" -match '^(HvServer|HvCluster)$' })) { Read-Inventory $hv "hv" }

# Find the host of every component
$dnsCache = @{}
function Get-NameVariants([string]$Name) {
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Name) { return , $out }
    $out.Add($Name)
    $ip = $null
    $isIp = [System.Net.IPAddress]::TryParse($Name, [ref]$ip)
    if (-not $isIp) { $out.Add($Name.Split(".")[0]) }
    if (-not $dnsCache.ContainsKey($Name)) {
        $dnsCache[$Name] = $null
        try { $dnsCache[$Name] = [System.Net.Dns]::GetHostEntry($Name) } catch { }
    }
    $he = $dnsCache[$Name]
    if ($he) {
        $out.Add($he.HostName); $out.Add($he.HostName.Split(".")[0])
        foreach ($a in $he.AddressList) { $out.Add($a.ToString()) }
    }
    return , $out
}

# Placement of the first name that matches: full names first, then IP addresses, then short names.
# A short name is the weakest key: "vbr" is also the first label of an unrelated VM name like "VBR.WIN.Demo".
function Find-Placement([string[]]$Names) {
    $vars = @(foreach ($nm in $Names) { foreach ($v in (Get-NameVariants $nm)) { if ($v) { $v.ToLower() } } })
    $ip = $null
    $ipVars = @($vars | Where-Object { [System.Net.IPAddress]::TryParse($_, [ref]$ip) })
    $nameVars = @($vars | Where-Object { $_ -notin $ipVars })
    foreach ($v in $nameVars + $ipVars) { if ($placeMap.ContainsKey($v)) { return $placeMap[$v] } }
    foreach ($v in $nameVars) { if ($placeShort.ContainsKey($v)) { return $placeShort[$v] } }
    return $null
}

# IPv4 addresses (no loopback / link-local), else global IPv6; comma-separated
function Select-Ips($Addrs) {
    $all = @(@($Addrs) | ForEach-Object { "$_" } | Where-Object { $_ } | Select-Object -Unique)
    $v4 = @($all | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^(127|169\.254)\.' })
    if ($v4.Count) { return $v4 -join ", " }
    return (@($all | Where-Object { $_ -match ':' -and $_ -notmatch '^(fe80|::1$)' }) -join ", ")
}

$placedCount = 0
foreach ($n in @($Nodes.Values)) {
    if ($n.kind -notin @("backup", "em", "vone", "proxy", "repo", "server")) { continue }
    # Virtual labs are placed already; tape libraries and Cloud Connect providers are not VMs
    if ($n["placement"] -or $n.id -match '^(tapelib|cloud):') { continue }
    $names = @()
    if ($n.details["Host"]) { $names += $n.details["Host"] }
    if ($n.kind -ne "repo") { $names += $n.name }
    if ($n.kind -eq "backup" -and $vbrLocal) { $names += [Environment]::MachineName }
    if ($n.kind -eq "backup" -and $vbrConnectedAs) { $names += $vbrConnectedAs }
    if (-not $names.Count) { continue }
    $hit = Find-Placement $names
    if (-not $hit) {
        $n["placement"] = [ordered]@{ host = $null; note = "Not found in the vSphere / Hyper-V inventory (physical or unmanaged)" }
        $n.details["Runs on"] = "Unknown / physical"
        continue
    }
    $hn = $hit.host
    $hid = $null
    $srv = $serverByName[$hn.ToLower()]
    if ($srv -and (Test-Node (Get-IdStr $srv))) { $hid = Get-IdStr $srv }
    if (-not $hid) {
        foreach ($x in $Nodes.Values) { if ($x.kind -in @("vi_host", "hv_host") -and $x.name -ieq $hn) { $hid = $x.id; break } }
    }
    if (-not $hid) {
        $hid = "place:$($hit.platform):$($hn.ToLower())"
        if ($hit.platform -eq "hv") { Add-Node $hid "hv_host" $hn "Hyper-V host · discovered via inventory" @("M") | Out-Null }
        else { Add-Node $hid "vi_host" $hn "ESXi · discovered via vCenter" | Out-Null }
    }
    $n["placement"] = [ordered]@{ host = $hn; vm = $hit.vm; source = $hit.source; platform = $hit.platform }
    $n["runsOn"] = $hid
    $n.details["Runs on"] = "$hn (VM: $($hit.vm))"
    $n.details["Matched by"] = $hit.source
    $guestIps = Select-Ips $hit.ips
    if ($guestIps) { $n.details["IP"] = "$guestIps (VM guest)" }
    $placedCount++
}
Write-Host ("  [OK]   {0,-28} {1}" -f "Components placed", $placedCount)

# IP addresses for the hover details: the VM's guest IPs (PowerCLI) when known, else DNS
foreach ($n in @($Nodes.Values)) {
    if ($n.kind -in @("agent", "sobr", "object") -or $n.details["IP"] -or $n.id -match '^(vlab|tapelib):') { continue }
    $nm = if ($n.details["Host"]) { $n.details["Host"] } elseif ($n.kind -ne "repo") { $n.name } else { $null }
    if (-not $nm) { continue }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($nm, [ref]$ip)) { $n.details["IP"] = $nm; continue }
    Get-NameVariants $nm | Out-Null   # fills the DNS cache
    $he = $dnsCache[$nm]
    if ($he) { $found = Select-Ips $he.AddressList; if ($found) { $n.details["IP"] = "$found (DNS)" } }
}

# vSphere cluster of each ESXi host (the report groups hosts by cluster)
foreach ($n in @($Nodes.Values)) {
    if ($n.kind -ne "vi_host") { continue }
    $c = $hostCluster[$n.name.ToLower()]
    if ($c) { $n["cluster"] = $c; $n.details["Cluster"] = $c.name }
}

# SOBR: summarize where the extents live (extents themselves are not drawn)
foreach ($n in @($Nodes.Values)) {
    if ($n.kind -ne "sobr" -or -not $n["extents"]) { continue }
    $parts = @(); $hostsSeen = @()
    foreach ($e in $n["extents"]) {
        if (-not (Test-Node $e)) { continue }
        $pl = $Nodes[$e]["placement"]
        $h = if ($pl -and $pl.host) { $pl.host } else { "Unknown" }
        $parts += "$($Nodes[$e].name) → $h"
        if ($h -notin $hostsSeen) { $hostsSeen += $h }
    }
    if ($parts.Count) {
        $n.details["Extent hosts"] = $parts -join "; "
        $n["placeLabel"] = "Extents: " + (($hostsSeen | ForEach-Object { $_.Split(".")[0] }) -join " / ")
    }
}

if ($connected) { try { Disconnect-VBRServer } catch { } }

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

$now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
$nodeList = New-Object System.Collections.Generic.List[object]
foreach ($k in $Nodes.Keys) { $nodeList.Add($Nodes[$k]) }
$linkList = New-Object System.Collections.Generic.List[object]
foreach ($k in $Links.Keys) { $l = $Links[$k]; $l["jobs"] = [string[]]$l["jobs"].ToArray(); $linkList.Add($l) }
$model = [ordered]@{
    generatedAt = $now
    lang = $Language
    vbr = [ordered]@{ name = $vbrName; base = $Server; apiVersion = "PowerShell"; build = $build; collectedAt = $now }
    nodes = $nodeList
    links = $linkList
    jobs = $JobRows
    backups = $BackupRows
    warnings = $script:Warnings
}

# One subfolder per run so earlier results are not overwritten
if (-not $NoTimestamp) {
    $short = ($vbrName.Split(".")[0]) -replace '[\\/:*?"<>|\s]', '_'
    $OutDir = Join-Path $OutDir ("{0}_{1}" -f $short, (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# [IO.File] resolves relative paths against the process directory (the Veeam Console folder once the
# module is loaded), not the PowerShell location, so pass it absolute paths
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
$json = ConvertTo-Json -InputObject $model -Depth 10
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutDir "topology.json"), $json, $utf8)

if (-not (Test-Path $Template)) { throw "template.html not found: $Template (keep it in the same folder as this script)" }
$Template = (Resolve-Path -LiteralPath $Template).ProviderPath
$tpl = [IO.File]::ReadAllText($Template, [Text.Encoding]::UTF8)
$html = $tpl.Replace("/*__MODEL__*/null", $json.Replace("</", "<\/"))
$htmlPath = Join-Path $OutDir "topology.html"
[IO.File]::WriteAllText($htmlPath, $html, $utf8)

$stats = $model.nodes | Group-Object { $_.kind } | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Nodes: " + ($stats -join ", "))
Write-Host "Data-flow links: $($model.links.Count)"
foreach ($w in $script:Warnings) { Write-Host "  Warning: $w" -ForegroundColor Yellow }
Write-Host "Done -> $htmlPath" -ForegroundColor Green
