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
    @("tape","tape01.corp.local","Windows"), @("old","oldsrv.corp.local","Windows"), @("abr1","abr01.corp.local","Linux"))) {
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
# MOCK_SESSION_HOST: the host the session is connected to (e.g. a short name or an IP), as in the Toolkit window
function Get-VBRServerSession { [pscustomobject]@{ Server = $(if ($env:MOCK_SESSION_HOST) { $env:MOCK_SESSION_HOST } else { "localhost" }) } }
function Get-VBRBackupServerInfo { [pscustomobject]@{ Build = [version]"12.3.1.1139" } }
function Get-VBRServer { $H.Values }
function Get-VBRViProxy {
    New-Obj @{ Id = (gid "vpx1"); Name = "vbrpx01.corp.local"; Host = $H.px1; IsDisabled = $false; Options = [pscustomobject]@{ TransportMode = "HotAdd"; MaxTasksCount = 8 } }
    New-Obj @{ Id = (gid "vpx2"); Name = "vbrpx02.corp.local"; Host = $H.px2; IsDisabled = $false; Options = [pscustomobject]@{ TransportMode = "Network"; MaxTasksCount = 4 } }
}
function Get-VBRHvProxy { New-Obj @{ Id = (gid "hvp"); Name = "hv01.corp.local"; Host = $H.hv1; Type = "OnHost"; MaxTasksCount = 4 } }
# General-purpose proxy: named after its server (the REST API calls it "Backup Proxy")
function Get-VBRNASProxyServer { New-Obj @{ Id = (gid "gpx"); Server = $H.repo1; ConcurrentTaskNumber = 4 } }
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
    $global:R1; $global:R4   # like VBR v12+: SOBR extents (R2, R3) are not returned; object storage (R4) is
}
$global:R4 = New-Obj @{ Id = (gid "r4"); Name = "Wasabi-Offsite"; Type = "WasabiCloud"; BucketName = "veeam-offsite" } @{
    GetActualGateways = { [pscustomobject]@{ Name = "repo01.corp.local" } } }
function Get-VBRObjectStorageRepository { $global:R4 }
# No Host, as in the lab: the managed server of the same name must not be listed again
function Get-VBRTapeServer { New-Obj @{ Id = (gid "tapesrv"); Name = "tape01.corp.local" } }
function Get-VBRTapeLibrary {
    New-Obj @{ Id = (gid "tlib"); Name = "HPE MSL3040"; Model = "MSL G3 Series"; TapeServerId = (gid "tapesrv"); Type = "Automated"
        State = "Online"; Slots = 40; Drives = @("Tape0", "Tape1") }
}
# Object: the source jobs (Backup to tape) or file shares (File to tape)
function Get-VBRTapeJob {
    New-Obj @{ Id = (gid "tj1"); Name = "Weekly-to-Tape"; Type = "BackupToTape"; Enabled = $true; Target = [pscustomobject]@{ Name = "GFS Media Pool" }; Object = @($J2) }
    New-Obj @{ Id = (gid "tj2"); Name = "Shares-to-Tape"; Type = "FileToTape"; Enabled = $false; Target = [pscustomobject]@{ Name = "Media Pool" }
        Object = @([pscustomobject]@{ Path = "\\nas01.corp.local\projects" }) }
}
# Virtual lab on esx01; Server prints as "<name>(<id>)" in the real module
function Get-VBRVirtualLab { New-Obj @{ Id = (gid "vlab"); Name = "Lab01"; Platform = "VMWare"; Server = $H.esx1 } }
function Get-VBRCloudProvider {
    New-Obj @{ Id = (gid "ccp"); DNSName = "cc.provider.example"; Port = 6180; Description = "Offsite backups"
        Resources = @([pscustomobject]@{ RepositoryName = "Cloud-Repo-01" }) }
}
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
# Replica: the metadata repository is the target repository id; the replica goes to esx02
$J7 = job "j7" "VMware-Replica-DR" "Replica" "EVmware" "r1" @() $true @("vcsa01.corp.local"); $J7.TypeToString = "VMware Replication"
$J7.Info | Add-Member TargetHostId (gid "esx2")
# Hyper-V replica without off-host proxies: host to host (on-host proxies), not through the VMware proxies
$J8 = job "j8" "HyperV-Replica-DR" "Replica" "EHyperV" "r1" @() $true @("hv01.corp.local"); $J8.TypeToString = "Hyper-V Replication"
$J8.Info | Add-Member TargetHostId (gid "hvc")
# Retention and encryption (Options.BackupStorageOptions), as in sample_raw.json. Plug-in jobs have none there.
function bso($job, $type, $n, $enc) {
    $job.Options | Add-Member BackupStorageOptions ([pscustomobject]@{ RetentionType = $type; RetainCycles = $(if ($type -eq "Cycles") { $n } else { 7 })
        RetainDaysToKeep = $(if ($type -eq "Days") { $n } else { 7 }); StorageEncryptionEnabled = $enc })
    # As on v13: every job has an unused file share retention default
    $job.Options | Add-Member NasBackupRetentionPolicy ([pscustomobject]@{ ShortTermRetention = 28; ShortTermRetentionUnit = "Day" })
}
bso $J1 "Cycles" 14 $true; bso $J2 "Days" 7 $false; bso $J3 "Days" 30 $false; bso $J7 "Cycles" 7 $false; bso $J8 "Cycles" 7 $false
# Last sessions (FindLastSession() on Get-VBRJob objects; session cmdlets for the others), as in sample_raw.json
function lastsess($job, $time, $result) {
    $job | Add-Member -Force -MemberType ScriptMethod -Name FindLastSession -Value ([scriptblock]::Create("[pscustomobject]@{ CreationTime = [datetime]'$time'; Result = '$result' }"))
}
lastsess $J1 "2026-10-27 22:00" "Success"; lastsess $J2 "2026-10-27 23:00" "Warning"; lastsess $J3 "2026-10-27 21:00" "Failed"; lastsess $J4 "2026-10-27 01:00" "Success"
function Get-VBRComputerBackupJobSession { [pscustomobject]@{ JobId = (gid "a1"); CreationTime = [datetime]"2026-10-27 20:00"; Result = "Success" } }
function Get-VBRNASBackupJobSession { [pscustomobject]@{ JobId = (gid "n1"); CreationTime = [datetime]"2026-10-27 19:00"; Result = "Success" } }
function Get-VBRSureBackupSession { [pscustomobject]@{ JobId = (gid "sb1"); CreationTime = [datetime]"2026-10-26 08:00"; Result = "Success" } }
function Get-VBRJob { $J1; $J2; $J3; $J4; $J5; $J6; $J7; $J8 }
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
# ExtendedChild: a VM VBR expanded itself (not set in the job), not listed in the report
$J7 | Add-Member _objs @((jo "app-sql01" "Virtual Machine" "$vc\DC01\vm\app-sql01" $vc),
    ([pscustomobject]@{ Name = "app-sql02"; Type = "ExtendedChild"; Location = "$vc\DC01\vm\app-sql02"; TypeDisplayName = "Virtual Machine" }))
$J8 | Add-Member _objs @((jo "app01" "Virtual Machine" "hv01.corp.local" "hv01.corp.local"))
function Get-VBRJobObject($Job) { $Job._objs }
function Get-VBRComputerBackupJob {
    New-Obj @{ Id = (gid "a1"); Name = "Agent-Windows"; OSPlatform = "Windows"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = $global:R1; BackupObject = @($PG1)
        RetentionType = "RestoreDays"; RetentionPolicy = 14; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false } }
    New-Obj @{ Id = (gid "a2"); Name = "Agent-Linux"; OSPlatform = "Linux"; Mode = "ManagedByBackupServer"; JobEnabled = $true; BackupRepository = (New-Obj @{ Id = (gid "sobr") }); BackupObject = @($PG2)
        RetentionType = "RestoreDays"; RetentionPolicy = 14; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false } }
    # A policy the agent manages: the repository is in DestinationOptions, BackupRepository is empty
    New-Obj @{ Id = (gid "a3"); Name = "Agent-Unix"; OSPlatform = "Unix"; Mode = "ManagedByAgent"; JobEnabled = $true; BackupRepository = $null
        DestinationOptions = [pscustomobject]@{ DestinationType = "BackupRepository"; BackupRepository = $global:R1 }; BackupObject = @($PG2)
        RetentionType = "RestoreDays"; RetentionPolicy = 7; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false } }
}
function Get-VBRBackupCopyJob {
    New-Obj @{ Id = (gid "c1"); Name = "Copy-to-Wasabi"; Mode = "Periodic"; JobEnabled = $true; BackupJob = @($J2); TargetRepository = $global:R4
        RetentionType = "Days"; RetentionNumber = 30; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $true } }
    # From an Application Backup Repository (the source is a repository, not a job)
    New-Obj @{ Id = (gid "c2"); Name = "ABR-to-Repo01"; Mode = "Immediate"; JobEnabled = $true; BackupJob = @()
        SourceRepository = (New-Obj @{ Id = (gid "abrvirtual"); Name = "Application Backup Repository"; Type = "AbrVirtual" })
        TargetRepository = $global:R1; RetentionType = "Days"; RetentionNumber = 7; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false } }
}
# Application Backup Repository (v13); Server prints as "name(id)" like the real object
$global:ABR = New-Obj @{ Id = (gid "abr"); Name = "Application Backup Repository"; ZFSPool = "veeam-stg-abr01"
    MountPath = "Application_Backup_Repository"; RetentionDays = 2; Description = ""; Server = $H["abr1"] }
function Get-VBRApplicationBackupRepository { $global:ABR }
function Get-VBREntraIDTenantBackupJob { New-Obj @{ Id = (gid "e1"); Name = "EntraID-Tenant"; JobEnabled = $true
    RetentionType = "RestoreDays"; RetentionPolicy = 7; EncryptionOptions = $false; Tenant = [pscustomobject]@{ Name = "corp.onmicrosoft.com" } } }
# A content scan (no virtual lab, linked jobs) and a SureBackup job with a virtual lab and an application group
function Get-VBRSureBackupJob {
    New-Obj @{ Id = (gid "sb1"); Name = "SureBackup-Prod"; IsEnabled = $false; LinkedJob = @([pscustomobject]@{ Job = $J1 }) }
    New-Obj @{ Id = (gid "sb2"); Name = "SureBackup-AppGroup"; IsEnabled = $true; LinkedJob = @()
        VirtualLab = [pscustomobject]@{ Name = "Lab01" }
        ApplicationGroup = [pscustomobject]@{ Name = "DC-AppGroup"; VM = @([pscustomobject]@{ Name = "dc01" }, [pscustomobject]@{ Name = "dc02" }) } }
}
if (-not ("Mock.VBRNASSMBServer" -as [type])) { Add-Type -TypeDefinition "namespace Mock { public class VBRNASSMBServer { } public class VBRAmazonS3ObjectStorageServer { } }" }
function Get-VBRNASBackupJob {
    New-Obj @{ Id = (gid "n1"); Name = "NAS-Shares"; JobEnabled = $true; ShortTermBackupRepository = $global:R1; ShortTermRetentionPeriod = 28; ShortTermRetentionType = "Daily"; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false }
        BackupObject = @([pscustomobject]@{ Path = "\\nas01.corp.local\projects"; Server = (New-Object Mock.VBRNASSMBServer)
                                            InclusionMask = @("*.docx", "*.xlsx"); ExclusionMask = @("\.snapshot", "*.tmp") }) }
    # Object storage: Path is the folder only, the bucket is separate (shown as "<bucket>/<folder>")
    New-Obj @{ Id = (gid "n2"); Name = "Bucket-Backup"; JobEnabled = $true; ShortTermBackupRepository = $global:R1; ShortTermRetentionPeriod = 28; ShortTermRetentionType = "Daily"; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false }
        BackupObject = @([pscustomobject]@{ Path = "/Backup/data/"; Container = [pscustomobject]@{ Name = "veeam-bucket" }
                                            Server = (New-Object Mock.VBRAmazonS3ObjectStorageServer) }) }
    # A Veeam Vault archive repository: no repository cmdlet returns it, only the job does
    New-Obj @{ Id = (gid "n5"); Name = "NAS-Archive"; JobEnabled = $true; ShortTermRetentionPeriod = 180; ShortTermRetentionType = "Daily"
        ShortTermBackupRepository = [pscustomobject]@{ Id = (gid "arch1"); Name = "Vault-Archive"; Group = "ArchiveRepository"; Type = "VeeamVaultAzureArchive"; Description = "" }
        StorageOptions = [pscustomobject]@{ EncryptionEnabled = $true }
        BackupObject = @([pscustomobject]@{ Path = "\\nas01.corp.local\archive"; Server = (New-Object Mock.VBRNASSMBServer) }) }
}
# v13 Get-VBRUnstructuredBackupJob also returns Entra ID audit log backups and file backup copies
function Get-VBRUnstructuredBackupJob { Get-VBRNASBackupJob; Get-VBREntraIDLogsBackupJob; Get-VBRNASBackupCopyJob }
function Get-VBREntraIDLogsBackupJob { New-Obj @{ Id = (gid "e2"); Name = "EntraID-AuditLogs"; JobEnabled = $true; ShortTermBackupRepository = $global:R1
    ShortTermRetentionPeriod = 28; ShortTermRetentionType = "Daily"; StorageOptions = [pscustomobject]@{ EncryptionEnabled = $false }
    BackupObject = [pscustomobject]@{ Tenant = [pscustomobject]@{ Name = "corp.onmicrosoft.com" } } } }
function Get-VBRNASBackupCopyJob {
    New-Obj @{ Id = (gid "n4"); Name = "NAS-Shares-Copy"; JobEnabled = $true; LinkedJobIds = @([guid](gid "n1"))   # as on v13: the source job's ID only
        TargetRepositoryId = $global:R4.Id; JobType = "NasBackupCopy"   # as on v13: the ID only
        # As on v13: the retention is in NasBackupRetentionPolicy, BackupStorageOptions keeps an unused 7-day default
        Options = [pscustomobject]@{
            NasBackupRetentionPolicy = [pscustomobject]@{ UseSpecificRetentionPolicy = $false; ShortTermRetention = 28; ShortTermRetentionUnit = "Day" }
            BackupStorageOptions = [pscustomobject]@{ RetentionType = "Days"; RetainCycles = 7; RetainDaysToKeep = 7; StorageEncryptionEnabled = $false } } }
}
# A CDP proxy, a CDP policy (sql01 on esx01 -> esx02) and the configuration backup
function Get-VBRCDPProxy { New-Obj @{ Id = (gid "cdp1"); Name = "vbrpx02.corp.local"; ServerId = (gid "px2"); CachePath = "/var/lib/veeam/veeam-cdp"; CacheSize = 100; CacheSizeUnit = "GB"; IsEnabled = $true; Description = "" } }
function Get-VBRCDPPolicy {
    New-Obj @{ Id = (gid "cdpp1"); Name = "CDP-SQL"; IsEnabled = $true; Entity = [pscustomobject]@{ Name = "app-sql01"; Host = $H.esx1 }
        Server = $H.esx2; MetadataRepository = $global:R1 }
}
function Get-VBRvCDReplicaJob { }
function Get-VBRConfigurationBackupJob { New-Obj @{ Name = "Backup Configuration Job"; Enabled = $true; Repository = $global:R1; EncryptionOptions = $true; RestorePointsToKeep = 10; LastResult = "Success" } }
# Backups and restore points (one backup file per restore point), matching sample_raw.json "backupFiles".
# app-sql01 has a point from an older chain (another object in VBR, same VM name: its own row)
function rpoint($name, $time, $gb, $obj = $name) {
    # The restore point is 2 minutes after its backup file was created (as in VBR)
    New-Obj @{ Id = [guid]::NewGuid(); Name = $name; ObjectId = (gid "obj-$obj"); CreationTime = ([datetime]$time).AddMinutes(2) } @{ GetStorage = [scriptblock]::Create("[pscustomobject]@{ Id = [guid]::NewGuid(); CreationTime = [datetime]'$time'; Stats = [pscustomobject]@{ BackupSize = [int64]$gb * 1GB } }") }
}
$global:RPs = @{
    "j1" = @((rpoint "app-sql01" "2026-10-20 22:00" 5 "app-sql01-old"), (rpoint "app-sql01" "2026-10-25 22:00" 120), (rpoint "app-sql01" "2026-10-26 22:00" 8), (rpoint "app-sql01" "2026-10-27 22:00" 8), (rpoint "app-web01" "2026-10-25 22:00" 40), (rpoint "app-web01" "2026-10-26 22:00" 3), (rpoint "app-web01" "2026-10-27 22:00" 3))
    "j2" = @((rpoint "dev01" "2026-10-26 23:00" 30), (rpoint "dev01" "2026-10-27 23:00" 2))
}
# Plug-in platform backup (j4): per-VM child backups and their backup files, read with internal methods
$global:AhvChild = New-Obj @{ Id = (gid "bj4c"); Name = "web01 Backup"; JobId = (gid "j4"); JobType = "VmbApiPolicyTempJob" }
function ahvfile($time, $gb) { [pscustomobject]@{ Id = [guid]::NewGuid(); BackupId = (gid "bj4c"); CreationTime = [datetime]$time; Stats = [pscustomobject]@{ BackupSize = [int64]$gb * 1GB } } }
$global:AhvFiles = @((ahvfile "2026-10-25 01:00" 20), (ahvfile "2026-10-26 01:00" 1), (ahvfile "2026-10-27 01:00" 1))
# j1 also has a per-machine child backup that returns the same restore points (counted once); an old
# backup without a job in the report fails and is not reported. Like VBR, Get-VBRRestorePoint refuses
# plug-in platform backups
function Get-VBRBackup {
    New-Obj @{ Id = (gid "bj1"); JobId = (gid "j1"); Name = "VMware-Prod-Daily"; JobType = "Backup"; Platform = "EVmware"; RepositoryId = (gid "sobr"); CreationTime = [datetime]"2026-06-01 22:00" }
    New-Obj @{ Id = (gid "bj2"); JobId = (gid "j2"); Name = "VMware-Dev"; JobType = "Backup"; Platform = "EVmware"; RepositoryId = (gid "r1"); CreationTime = [datetime]"2026-07-01 23:00" }
    New-Obj @{ Id = (gid "bj1c"); JobId = (gid "j1"); Name = "VMware-Prod-Daily (child)"; JobType = "Backup"; Platform = "EVmware"; RepositoryId = (gid "sobr") }
    New-Obj @{ Id = (gid "bj4"); JobId = (gid "j4"); Name = "AHV-Daily"; JobType = "VmbApiPolicyTempJob"; Platform = "ECustomPlatform"
        PlatformId = [guid]"799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2"; RepositoryId = (gid "r1"); CreationTime = [datetime]"2026-08-01 01:00" } @{
        FindChildBackups = { @($global:AhvChild) }; GetAllChildrenStorages = { $global:AhvFiles } }
    $global:AhvChild
    New-Obj @{ Id = (gid "bold"); JobId = (gid "oldjob"); Name = "Old-Backup"; JobType = "Backup"; Platform = "EVmware"; RepositoryId = (gid "r1"); CreationTime = [datetime]"2025-01-15 22:00" }
}
function Get-VBRRestorePoint($Backup) {
    if ("$($Backup.JobType)" -eq "VmbApiPolicyTempJob" -or $Backup.Id -eq (gid "bj4c") -or $Backup.Id -eq (gid "bold")) {
        throw "Cannot get restore points from backup $($Backup.Name), because it is encrypted or created by an enterprise application plug-in."
    }
    $k = @($global:RPs.Keys | Where-Object { (gid $_) -eq $Backup.JobId })[0]
    if ($k) { $global:RPs[$k] }
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
    # Two clusters: the report groups the hosts by cluster
    $p = "vcsa01.corp.local\DC01\Prod-Cluster"; $q = "vcsa01.corp.local\DC01\DR-Cluster"
    [pscustomobject]@{ Name = "Prod-Cluster";     Type = "Cluster"; Path = $p }
    [pscustomobject]@{ Name = "DR-Cluster";       Type = "Cluster"; Path = $q }
    [pscustomobject]@{ Name = "esx01.corp.local"; Type = "Host"; Path = "$p\esx01.corp.local" }
    [pscustomobject]@{ Name = "esx02.corp.local"; Type = "Host"; Path = "$q\esx02.corp.local" }
    # Its first label is "vbr01" too: must not place the backup server (exact names win over short names)
    [pscustomobject]@{ Name = "VBR01.WIN.Demo";   Type = "Vm";   Path = "$q\esx02.corp.local\VBR01.WIN.Demo" }
    [pscustomobject]@{ Name = "vbr01";            Type = "Vm";   Path = "$p\esx01.corp.local\vbr01" }
    [pscustomobject]@{ Name = "em01";             Type = "Vm";   Path = "$p\esx01.corp.local\em01" }
    [pscustomobject]@{ Name = "vbrpx01";          Type = "Vm";   Path = "$p\esx01.corp.local\vbrpx01" }
    [pscustomobject]@{ Name = "vbrpx02.corp.local"; Type = "Vm"; Path = "$q\esx02.corp.local\vbrpx02.corp.local" }
    [pscustomobject]@{ Name = "lhr01";            Type = "Vm";   Path = "$q\esx02.corp.local\lhr01" }
    [pscustomobject]@{ Name = "app-sql01";        Type = "Vm";   Path = "$q\esx02.corp.local\app-sql01" }
}
function Find-VBRHvEntity($Server) { }
