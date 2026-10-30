# Mock Veeam PowerShell cmdlets returning fake objects (offline tests of Get-VBRTopology.ps1 only)
function New-Obj([hashtable]$h, [hashtable]$methods = @{}) {
    $o = [pscustomobject]$h
    foreach ($k in $methods.Keys) { $o | Add-Member -MemberType ScriptMethod -Name $k -Value $methods[$k] }
    $o
}
$G = @{}; function gid($k) { if (-not $G[$k]) { $G[$k] = [guid]::NewGuid() }; $G[$k] }
$H = @{}
foreach ($s in @(
    @("vbr","vbr01.corp.local","Local"), @("vc","vcsa01.corp.local","VC"), @("hv1","hv01.corp.local","HvServer"),
    @("hvc","hvclu01.corp.local","HvCluster"), @("px1","vbrpx01.corp.local","Windows"), @("px2","vbrpx02.corp.local","Linux"),
    @("repo1","repo01.corp.local","Windows"), @("lhr1","lhr01.corp.local","Linux"), @("lhr2","lhr02.corp.local","Linux"),
    @("tape","tape01.corp.local","Windows"), @("old","oldsrv.corp.local","Windows"))) {
    $H[$s[0]] = New-Obj @{ Id = (gid $s[0]); Name = $s[1]; Type = $s[2]; Description = ""; IsUnavailable = $false }
}
# vSphere version strings, as Get-VBRServer returns them in Info.Info (two ESXi versions -> mixed-version warning)
$H.vc | Add-Member Info ([pscustomobject]@{ Info = "VMware vCenter Server 8.0.3 build-24322831" })
foreach ($s in @(@("esx1", "esx01.corp.local", "8.0.3 build-24280767"), @("esx2", "esx02.corp.local", "7.0.3 build-21930508"))) {
    $H[$s[0]] = New-Obj @{ Id = (gid $s[0]); Name = $s[1]; Type = "ESXi"; Description = ""; IsUnavailable = $false
        Info = [pscustomobject]@{ Info = "VMware ESXi $($s[2])" } }
}
# Plug-in platforms: the platform ID is only in the physical host name
foreach ($s in @(@("pve", "pve01.corp.local", "01208ee8-47fe-4ea8-8727-5115874da1ad"), @("pve2", "pve02.corp.local", "01208ee8-47fe-4ea8-8727-5115874da1ad"),
                 @("ahv", "ahv01.corp.local", "799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2"),
                 @("vme", "VMECluster", "2d470d24-b6bb-4fa3-b7ff-f0fc1137ca52"), @("ext", "other01.corp.local", "00000000-1111-2222-3333-444444444444"))) {
    $phys = "ExternalInfrastructureOfServer_$(gid ($s[0] + 'p'))_platform_$($s[2])"
    $H[$s[0]] = New-Obj @{ Id = (gid $s[0]); Name = $s[1]; Type = "ExternalInfrastructureServer"; Description = ""; IsUnavailable = $false
        Info = [pscustomobject]@{ Info = "" } } @{ GetPhysicalHost = [scriptblock]::Create("[pscustomobject]@{ Name = '$phys' }") }
}
function Get-VBRServerSession { [pscustomobject]@{ Server = "localhost" } }
function Get-VBRBackupServerInfo { [pscustomobject]@{ Build = [version]"12.3.1.1139" } }
function Get-VBRServer { $H.Values }
function Get-VBRViProxy {
    New-Obj @{ Id = (gid "vpx1"); Name = "vbrpx01.corp.local"; Host = $H.px1; IsDisabled = $false; Options = [pscustomobject]@{ TransportMode = "HotAdd"; MaxTasksCount = 8 } }
    New-Obj @{ Id = (gid "vpx2"); Name = "vbrpx02.corp.local"; Host = $H.px2; IsDisabled = $false; Options = [pscustomobject]@{ TransportMode = "Network"; MaxTasksCount = 4 } }
}
function Get-VBRHvProxy { New-Obj @{ Id = (gid "hvp"); Name = "hv01.corp.local"; Host = $H.hv1; Type = "OnHost"; MaxTasksCount = 4 } }
function Get-VBRNASProxyServer { throw "not licensed" }
function Get-VBRWANAccelerator { }
function cont($t, $f) { New-Obj @{} @{ GetContainer = [scriptblock]::Create("[pscustomobject]@{ CachedTotalSpace = [pscustomobject]@{ InGigabytes = $t }; CachedFreeSpace = [pscustomobject]@{ InGigabytes = $f } }") } }
function Get-VBRBackupRepository([switch]$ScaleOut) {
    if ($ScaleOut) {
        return New-Obj @{ Id = (gid "sobr"); Name = "SOBR-Immutable"; EnableCapacityTier = $true
            Extent = @([pscustomobject]@{ Repository = $global:R2 }, [pscustomobject]@{ Repository = $global:R3 })
            CapacityExtent = [pscustomobject]@{ Repository = $global:R4 } }
    }
    $global:R1 = New-Obj @{ Id = (gid "r1"); Name = "Repo01-ReFS"; Type = "WinLocal"; HostId = (gid "repo1"); FriendlyPath = "E:\Backups" } @{ GetContainer = { [pscustomobject]@{ CachedTotalSpace = [pscustomobject]@{ InGigabytes = 40000 }; CachedFreeSpace = [pscustomobject]@{ InGigabytes = 12000 } } } }
    $global:R2 = New-Obj @{ Id = (gid "r2"); Name = "LHR01"; Type = "LinuxHardened"; HostId = (gid "lhr1"); FriendlyPath = "/mnt/veeam" } @{ GetContainer = { [pscustomobject]@{ CachedTotalSpace = [pscustomobject]@{ InGigabytes = 100000 }; CachedFreeSpace = [pscustomobject]@{ InGigabytes = 61000 } } } }
    $global:R3 = New-Obj @{ Id = (gid "r3"); Name = "LHR02"; Type = "LinuxHardened"; HostId = (gid "lhr2"); FriendlyPath = "/mnt/veeam" }
    $global:R1; $global:R2; $global:R3
}
$global:R4 = New-Obj @{ Id = (gid "r4"); Name = "Wasabi-Offsite"; Type = "WasabiCloud"; BucketName = "veeam-offsite" }
function Get-VBRObjectStorageRepository { $global:R4 }
function Get-VBRTapeServer { New-Obj @{ Id = (gid "tapesrv"); Name = "tape01.corp.local"; Host = $H.tape } }
$PG1 = New-Obj @{ Id = (gid "pg1"); Name = "Physical Windows Servers"; Container = [pscustomobject]@{ Type = "IndividualComputers" } }
$PG2 = New-Obj @{ Id = (gid "pg2"); Name = "Linux AD OU"; Container = [pscustomobject]@{ Type = "ADObjects" } }
function Get-VBRProtectionGroup { $PG1; $PG2 }
function Get-VBRDiscoveredComputer($ProtectionGroup) { 1..3 }
function job($k, $name, $type, $plat, $repoKey, $proxies, $auto, $hosts) {
    $px = $proxies
    New-Obj @{ Id = (gid $k); Name = $name; JobType = $type; BackupPlatform = [pscustomobject]@{ Platform = $plat }; TypeToString = "$plat $type"
        IsScheduleEnabled = $true; Info = [pscustomobject]@{ TargetRepositoryId = (gid $repoKey) }
        Options = [pscustomobject]@{ JobOptions = [pscustomobject]@{ SourceProxyAutoDetect = $auto } }; _hosts = $hosts } @{
        GetProxy = [scriptblock]::Create("@(" + (($px | ForEach-Object { "[pscustomobject]@{Id=[guid]'$(gid $_)'}" }) -join ",") + ")") }
}
$J1 = job "j1" "VMware-Prod-Daily" "Backup" "EVmware" "sobr" @("vpx1","vpx2") $false @("vcsa01.corp.local")
$J2 = job "j2" "VMware-Dev" "Backup" "EVmware" "r1" @() $true @("vcsa01.corp.local")
$J3 = job "j3" "HyperV-Daily" "Backup" "EHyperV" "r1" @() $true @("hv01.corp.local","hvclu01.corp.local")
# TypeToString as VBR shows it
$J1.TypeToString = "VMware Backup"; $J2.TypeToString = "VMware Backup"; $J3.TypeToString = "Hyper-V Backup"
# Plug-in jobs: the platform is only in TypeToString. Proxmox names its cluster, not a registered host.
$J4 = job "j4" "AHV-Daily" "VmbApiPolicyTempJob" "" "r1" @() $true @("ahv01.corp.local"); $J4.TypeToString = "Nutanix AHV Backup"
$J5 = job "j5" "Proxmox-Daily" "VmbApiPolicyTempJob" "" "r1" @() $true @("pveclu01"); $J5.TypeToString = "Proxmox Backup"
$J6 = job "j6" "VME-Daily" "VmbApiPolicyTempJob" "" "r1" @() $true @("VMECluster"); $J6.TypeToString = "HPE Morpheus VME Backup"
function Get-VBRJob { $J1; $J2; $J3; $J4; $J5; $J6 }
# Job objects as Get-VBRJobObject returns them. Plug-in objects have no Location, only Object.Host.
function jo($name, $disp, $loc, $hostName, $excl = $false, $size = "") {
    [pscustomobject]@{ Name = $name; Type = $(if ($excl) { "Exclude" } else { "Include" }); Location = $loc; TypeDisplayName = $disp
        ApproxSizeString = $size; Object = [pscustomobject]@{ Host = [pscustomobject]@{ Name = $hostName } } }
}
$vc = "vcsa01.corp.local"
$J1 | Add-Member _objs @((jo "Prod-Cluster" "Cluster" "$vc\DC01\Prod-Cluster" $vc $false "1.2 TB"),
    (jo "SQL-Servers" "Folder" "$vc\DC01\vm\SQL-Servers" $vc $false "640 GB"), (jo "test-sql01" "Virtual Machine" "$vc\DC01\vm\SQL-Servers\test-sql01" $vc $true "80 GB"))
$J2 | Add-Member _objs @((jo "Dev" "Resource Pool" "$vc\DC01\Prod-Cluster\Dev" $vc $false "300 GB"))
$J3 | Add-Member _objs @((jo "app01" "Virtual Machine" "hv01.corp.local" "hv01.corp.local"), (jo "hvclu01.corp.local" "Cluster" "hvclu01.corp.local" "hvclu01.corp.local"))
$J4 | Add-Member _objs @((jo "web01" "Virtual Machine" "" "ahv01.corp.local"), (jo "web02" "Virtual Machine" "" "ahv01.corp.local"))
$J5 | Add-Member _objs @((jo "pve-vm01" "Virtual Machine" "" "pveclu01"))
$J6 | Add-Member _objs @((jo "vme-app01" "Virtual Machine" "" "VMECluster"))
function Get-VBRJobObject($Job) { $Job._objs }
function Get-VBRComputerBackupJob {
    New-Obj @{ Id = (gid "a1"); Name = "Agent-Windows"; OSPlatform = "Windows"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = $global:R1; BackupObject = @($PG1) }
    New-Obj @{ Id = (gid "a2"); Name = "Agent-Linux"; OSPlatform = "Linux"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = (New-Obj @{ Id = (gid "sobr") }); BackupObject = @($PG2) }
}
function Get-VBRBackupCopyJob { New-Obj @{ Id = (gid "c1"); Name = "Copy-to-Wasabi"; Mode = "Periodic"; JobEnabled = $true; BackupJob = @($J2); TargetRepository = $global:R4 } }
if (-not ("Mock.VBRNASSMBServer" -as [type])) { Add-Type -TypeDefinition "namespace Mock { public class VBRNASSMBServer { } }" }
function Get-VBRNASBackupJob {
    New-Obj @{ Id = (gid "n1"); Name = "NAS-Shares"; JobEnabled = $true; ShortTermBackupRepository = $global:R1
        BackupObject = @([pscustomobject]@{ Path = "\\nas01.corp.local\projects"; Server = (New-Object Mock.VBRNASSMBServer)
                                            InclusionMask = @(); ExclusionMask = @("\.snapshot", "*.tmp") }) }
}
# Mock Enterprise Manager registration info
if (-not ("Veeam.Backup.Core.SBackupOptions" -as [type])) {
    Add-Type -TypeDefinition @"
namespace Veeam.Backup.Core {
  public class EmInfo { public string ServerName; public string URL; public bool IsConnected; public bool SkipLicensePush; }
  public static class SBackupOptions {
    public static EmInfo GetEnterpriseServerInfo() { return new EmInfo { ServerName = "em01.corp.local", URL = "https://em01.corp.local:9443", IsConnected = true }; }
  }
}
"@
}
# Mock vCenter inventory (Hosts and Clusters view)
function Find-VBRViEntity($Server, [switch]$HostsAndClusters) {
    $p = "vcsa01.corp.local\DC01\Prod-Cluster"
    [pscustomobject]@{ Name = "esx01.corp.local"; Type = "Host"; Path = "$p\esx01.corp.local" }
    [pscustomobject]@{ Name = "esx02.corp.local"; Type = "Host"; Path = "$p\esx02.corp.local" }
    [pscustomobject]@{ Name = "vbr01";            Type = "Vm";   Path = "$p\esx01.corp.local\vbr01" }
    [pscustomobject]@{ Name = "em01";             Type = "Vm";   Path = "$p\esx01.corp.local\em01" }
    [pscustomobject]@{ Name = "vbrpx01";          Type = "Vm";   Path = "$p\esx01.corp.local\vbrpx01" }
    [pscustomobject]@{ Name = "vbrpx02.corp.local"; Type = "Vm"; Path = "$p\esx02.corp.local\vbrpx02.corp.local" }
    [pscustomobject]@{ Name = "lhr01";            Type = "Vm";   Path = "$p\esx02.corp.local\lhr01" }
    [pscustomobject]@{ Name = "app-sql01";        Type = "Vm";   Path = "$p\esx02.corp.local\app-sql01" }
}
function Find-VBRHvEntity($Server) { }
