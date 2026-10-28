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
function Get-VBRJob { $J1; $J2; $J3 }
function Get-VBRJobObject($Job) { foreach ($h in $Job._hosts) { [pscustomobject]@{ Name = "x"; Location = "$h\Datacenter\Cluster" } } }
function Get-VBRComputerBackupJob {
    New-Obj @{ Id = (gid "a1"); Name = "Agent-Windows"; OSPlatform = "Windows"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = $global:R1; BackupObject = @($PG1) }
    New-Obj @{ Id = (gid "a2"); Name = "Agent-Linux"; OSPlatform = "Linux"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = (New-Obj @{ Id = (gid "sobr") }); BackupObject = @($PG2) }
}
function Get-VBRBackupCopyJob { New-Obj @{ Id = (gid "c1"); Name = "Copy-to-Wasabi"; Mode = "Periodic"; JobEnabled = $true; BackupJob = @($J2); TargetRepository = $global:R4 } }
function Get-VBRNASBackupJob { }
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
