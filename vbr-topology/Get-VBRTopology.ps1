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

$build = $null
try { $build = (Get-VBRBackupServerInfo).Build.ToString() } catch { }
if (-not $build) {
    try {
        $dll = Join-Path ${env:ProgramFiles} "Veeam\Backup and Replication\Console\Veeam.Backup.Core.dll"
        $build = (Get-Item $dll).VersionInfo.ProductVersion
    } catch { }
}
$vbrName = $Server
if ($Server -in @("localhost", ".", "127.0.0.1")) {
    try { $vbrName = [System.Net.Dns]::GetHostEntry([Environment]::MachineName).HostName } catch { $vbrName = [Environment]::MachineName }
}

# ---------------------------------------------------------------------------
# Build nodes
# ---------------------------------------------------------------------------

Add-Node "vbr" "backup" $vbrName "Backup server · v$build" @() @{ Build = $build; Server = $vbrName } | Out-Null

# ---- Enterprise Manager / Veeam ONE (management tier)
# There is no official cmdlet that returns the EM a VBR is registered to. Use the
# internal API that community tools rely on, plus a local service check and the
# -EnterpriseManager parameter.
$mgmtSeen = @{}
function Add-Mgmt([string]$Kind, [string]$Name, [string]$Sub, $Details) {
    if (-not $Name) { return }
    $key = "${Kind}:$($Name.ToLower())"
    if ($mgmtSeen[$key]) { foreach ($k in $Details.Keys) { if ($Details[$k]) { $Nodes[$mgmtSeen[$key]].details[$k] = "$($Details[$k])" } }; return }
    if ($Name -ieq $vbrName -or $Name -ieq [Environment]::MachineName) { $Sub += " · same host as VBR" }
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
    if ($s.Name -ieq $vbrName -or $t -eq "Local" -or $s.Name -ieq [Environment]::MachineName) { [void]$UsedHosts.Add($id) }
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

$proxyByType = @{ ViProxy = @(); HvProxy = @(); GeneralPurposeProxy = @() }

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
foreach ($w in $wans) {
    $id = Get-IdStr $w; [void]$UsedHosts.Add((Resolve-HostId $w))
    Add-Node $id "proxy" $w.Name "WAN accelerator" @("M") @{ Host = (Resolve-HostName $w); Description = $w.Description } | Out-Null
}
foreach ($t in $tapes) {
    $id = Get-IdStr $t; [void]$UsedHosts.Add((Resolve-HostId $t))
    Add-Node $id "server" $t.Name "Tape server" @("M") @{ Host = (Resolve-HostName $t); Description = $t.Description } | Out-Null
}

# SOBR extent lookup
$extentOf = @{}
foreach ($sb in $sobrs) {
    foreach ($e in @($sb.Extent)) { if ($e) { $extentOf[(Get-IdStr (Get-Prop $e @("Repository", "Id")))] = (Get-IdStr $sb) } }
}

$dedupTypes = "DDBoost|ExaGrid|StoreOnce|Quantum|Infinidat|Fujitsu"
foreach ($r in $repos) {
    $id = Get-IdStr $r; $t = "$($r.Type)"
    $hid = Resolve-HostId $r; if ($hid) { [void]$UsedHosts.Add($hid) }
    $cap = $null; $free = $null
    try { $c = $r.GetContainer(); $cap = $c.CachedTotalSpace.InGigabytes; $free = $c.CachedFreeSpace.InGigabytes } catch { }
    $gw = $null
    try { $gw = (@($r.GetActualGateways()) | ForEach-Object { $_.Name }) -join ", " } catch { }
    if ($t -match "Cifs|Smb|Nfs") { $kind = "repo"; $label = "NAS share · $t"; $badges = @() }
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
foreach ($o in $objRepos) {
    $id = Get-IdStr $o
    Add-Node $id "object" $o.Name "Object storage · $($o.Type)" @() @{
        Type = "$($o.Type)"; Bucket = (Get-Prop $o @("AmazonBucket.Name", "Bucket.Name", "Container.Name", "BucketName")); Description = $o.Description } | Out-Null
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
    # Capacity tier object storage: SOBR -> object (offload)
    foreach ($ce in $capExt) { $cid = Get-IdStr (Get-Prop $ce @("Repository", "Id")); if ((Test-Node $cid)) { Add-Link $sid $cid "Capacity tier offload" "copy" } }
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

$JobRows = New-Object System.Collections.Generic.List[object]
$jobRepo = @{}   # job id -> repo id (used to find backup copy sources)
# These jobs are handled by their own cmdlets; skip them in Get-VBRJob to avoid duplicates
$handledElsewhere = New-Object System.Collections.Generic.HashSet[string]
foreach ($x in @($copyJobs) + @($agentJobs) + @($nasJobs)) { if ($x) { [void]$handledElsewhere.Add((Get-IdStr $x)) } }

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
    foreach ($o in $objs) {
        $h = Get-Prop $o @("Object.Host.Name", "Host.Name")
        if (-not $h -and $o.Location) { $h = ($o.Location -split '[\\/]')[0] }
        if ($h) { [void]$hosts.Add($h) }
    }
    $sel = @(); try { $sel = @($j.GetProxy() | ForEach-Object { Get-IdStr $_ } | Where-Object { (Test-Node $_) }) } catch { }
    $auto = Get-Prop $j @("Options.JobOptions.SourceProxyAutoDetect")
    if ($auto -eq $true) { $sel = @() }

    $JobRows.Add([ordered]@{ name = $j.Name; type = $(if ($typeStr) { $typeStr } else { $type }); disabled = $disabled
        repository = $(if ((Test-Node $repo)) { $Nodes[$repo].name } else { $null }); sources = @($hosts)
        proxies = $(if ($sel.Count) { ($sel | ForEach-Object { $Nodes[$_].name }) -join ", " } else { "Automatic" }) })

    if ($all -match "Copy|BackupSync|SimpleBackupCopy") {
        $srcRepos = @()
        foreach ($lj in @(Get-Prop $j @("LinkedJobIds"))) { if ($lj) { $srcRepos += $jobRepo["$lj"] } }
        foreach ($lr in @(Get-Prop $j @("LinkedRepositoryIds"))) { if ($lr) { $srcRepos += "$lr" } }
        foreach ($sr in $srcRepos) { Add-Link $sr $repo $label "copy" }
        continue
    }
    if ($all -match "Replica") {
        $tgt = "$(Get-Prop $j @('Info.TargetHostId', 'TargetHostId'))"
        $px = if ($sel.Count) { $sel } else { $proxyByType.ViProxy }
        foreach ($h in $hosts) { $src = Resolve-SourceNode $h $(if ($all -match "Hv|HyperV") { "hv" } else { "vi" }); foreach ($p in $px) { Add-Link $src $p $label "auto" } }
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

# Agent jobs (v12+ cmdlet)
foreach ($a in $agentJobs) {
    $repo = Get-IdStr (Get-Prop $a @("BackupRepository", "TargetRepository"))
    $enabled = Get-Prop $a @("JobEnabled", "IsEnabled")
    $label = $a.Name + $(if ($enabled -eq $false) { " (disabled)" } else { "" })
    $pgIds = @(@($a.BackupObject) | ForEach-Object { Get-IdStr (Get-Prop $_ @("Container", "ProtectionGroup")); Get-IdStr $_ } |
               Where-Object { $_ -and (Test-Node $_) -and $Nodes[$_].kind -eq "agent" })
    if (-not $pgIds.Count) { Add-Node "agents" "agent" "Veeam Agents" "Physical / virtual servers" @("A") | Out-Null; $pgIds = @("agents") }
    foreach ($pg in $pgIds) { Add-Link $pg $repo $label }
    $JobRows.Add([ordered]@{ name = $a.Name; type = "Agent backup ($($a.OSPlatform), $($a.Mode))"; disabled = ($enabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null })
        sources = @($pgIds | ForEach-Object { $Nodes[$_].name }); proxies = "—" })
}

# Backup copy jobs (v12+ cmdlet)
foreach ($c in $copyJobs) {
    $tgt = Get-IdStr (Get-Prop $c @("TargetRepository", "Target.Repository", "Repository", "BackupRepository"))
    $srcRepos = @()
    foreach ($sj in @($c.BackupJob)) { if ($sj) { $srcRepos += $jobRepo[(Get-IdStr $sj)] } }
    foreach ($sr in @(Get-Prop $c @("SourceRepository", "Repository"))) { if ($sr -and (Get-IdStr $sr) -ne $tgt) { $srcRepos += (Get-IdStr $sr) } }
    foreach ($sr in $srcRepos) { if ($sr) { Add-Link $sr $tgt $c.Name "copy" } }
    $JobRows.Add([ordered]@{ name = $c.Name; type = "Backup copy ($($c.Mode))"; disabled = ($c.JobEnabled -eq $false)
        repository = $(if ((Test-Node "$tgt")) { $Nodes["$tgt"].name } else { $null })
        sources = @($c.BackupJob | Where-Object { $_ } | ForEach-Object { $_.Name }); proxies = "—" })
}

# File share / NAS backup
foreach ($n in $nasJobs) {
    $repo = Get-IdStr (Get-Prop $n @("ShortTermBackupRepository", "BackupRepository", "StorageRepository"))
    foreach ($p in $proxyByType.GeneralPurposeProxy) { Add-Link $p $repo $n.Name "auto" }
    $JobRows.Add([ordered]@{ name = $n.Name; type = "File backup"; disabled = ($n.JobEnabled -eq $false)
        repository = $(if ((Test-Node "$repo")) { $Nodes["$repo"].name } else { $null }); sources = @(); proxies = "Automatic" })
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
$placeMap = @{}   # lowercase name / IP -> placement
function Add-PlaceKey([string]$Key, $Info) {
    # Entries without a host name (e.g. a VM on a disconnected host) cannot place anything
    if (-not $Key -or -not $Info -or -not $Info.host) { return }
    $k = $Key.Trim().ToLower()
    if ($k -and -not $placeMap.ContainsKey($k)) { $placeMap[$k] = $Info }
}
function Add-PlaceKeys([string]$Name, $Info) {
    if (-not $Name) { return }
    Add-PlaceKey $Name $Info
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Name, [ref]$ip)) { Add-PlaceKey ($Name.Split(".")[0]) $Info }
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
                    $info = @{ host = $vm.VMHost.Name; vm = $vm.Name; source = "PowerCLI ($($vc.Name))"; platform = "vi" }
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

$placedCount = 0
foreach ($n in @($Nodes.Values)) {
    if ($n.kind -notin @("backup", "em", "vone", "proxy", "repo", "server")) { continue }
    $names = @()
    if ($n.details["Host"]) { $names += $n.details["Host"] }
    if ($n.kind -ne "repo") { $names += $n.name }
    if ($n.kind -eq "backup") { $names += [Environment]::MachineName }
    if (-not $names.Count) { continue }
    $hit = $null
    foreach ($nm in $names) {
        foreach ($v in (Get-NameVariants $nm)) { if ($v -and $placeMap.ContainsKey($v.ToLower())) { $hit = $placeMap[$v.ToLower()]; break } }
        if ($hit) { break }
    }
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
    $placedCount++
}
Write-Host ("  [OK]   {0,-28} {1}" -f "Components placed", $placedCount)

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
