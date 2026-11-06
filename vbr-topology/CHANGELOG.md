# Changelog: vbr-topology

## Known limitations

Current as of v1.10.0 (checked on VBR v13.1, REST API 1.3-rev2).

**Testing**

- Tested on VBR v13.1 in two labs (vCenter 8.0.3, ESXi 7.0.3 and 8.0.3, one Hyper-V cluster) and against
  the offline mocks. Results were compared with the VBR console.
- CDP policies, Cloud Director replication jobs and storage copy jobs were not in the labs; what
  PowerShell reads for CDP policies and Cloud Director replication jobs has only been tested against the
  mocks.
- The plug-in platform IDs (Nutanix AHV, Proxmox VE, HPE Morpheus VME) were taken from one lab; other
  plug-in versions may use other IDs.
- Job retention and encryption in PowerShell: only `Get-VBRJob`'s `BackupStorageOptions` follows a known
  layout. For agent, backup copy, file share and Entra ID jobs several property names are tried, which has
  only been tested against the mocks; a name that does not match leaves the value empty.

**Both collectors**

- The proxies (workers) of plug-in platforms are not shown: PowerShell does not expose them
  (`GetChilds()` / `GetSubHosts()` return nothing), and REST lists `NutanixAHV` and `PVE` in `EProxyType`
  but `/proxies` returns none of them.
- Storage copy jobs (HPE StoreOnce Catalyst Copy, Dell Data Domain Managed File Replication) are not listed.
- Object storage backup jobs are labeled `File backup`, as `Get-VBRUnstructuredBackupJob` does not tell
  them apart from file share backups.
- Backup copies from an Application Backup Repository report a size on disk of 0.
- Without PowerCLI or `--vcenter-user`, components are matched to hosts by VM name only. Proxies
  registered by IP, and VMs whose name differs from their hostname, show as "Physical / unknown host".
- As in the VBR console, a job shows no last result without a last run time, and N/A for agent policies
  the agent manages itself.
- Retention is the job's short-term retention only (no GFS). Replicas, CDP policies, SureBackup and tape
  jobs show no encryption.

**PowerShell**

- Some data comes from .NET methods and internal classes that Veeam does not support (see the
  [PowerShell FAQ](https://forums.veeam.com/viewtopic.php?f=26&t=89480) on the R&D Forums):
  `SBackupOptions.GetEnterpriseServerInfo()` (Enterprise Manager), `GetHost()` (proxy and repository hosts),
  `GetContainer()` (repository capacity and free space), `GetActualGateways()` (gateways),
  `GetTargetRepository()` and `GetProxy()` (job targets and proxies), `GetPhysicalHost()` (plug-in platform
  type), `Info.Info` (vCenter / ESXi versions), `GetStorage()` (size of a restore point's backup file),
  `FindChildBackups()` / `GetAllChildrenStorages()` (restore points of plug-in platform backups) and
  `FindLastSession()` (a job's last run and result). Each call is wrapped, so a change in a VBR update
  leaves that detail empty instead of stopping the scan.
- A PowerShell window that is already connected to a VBR server keeps that session: `-Server` is ignored.
  Open a new window to scan another server.
- The Backups table has no storage-snapshot backups and no file share, object storage or Entra ID
  backups: `Get-VBRBackup` does not return them.
- Cloud Director backups show VM names with a suffix (`DC-01-ZDsW`) and count each VM's restore points
  from the vApp's, so they can differ from the console.
- A backup's creation time is its oldest backup file, as `CreationTime` can be the date of a VBR upgrade;
  for a copied or imported backup the console shows a later date.
- No last run (and so no last result) for tape jobs, the configuration backup and Entra ID tenant backups:
  their cmdlets give no run time, and VBR v13.1 has no Entra ID session cmdlet.
- Entra ID tenant backup jobs have no enabled / disabled state (only `EnableSchedule`), so they always show
  as enabled.
- Repositories without a host of their own (object storage, dedup appliances) are placed on their gateway
  server (often the VBR server).

**Python (REST API)**

- Not in the REST API, so not in the report: tape servers, libraries and jobs; SureBackup virtual labs and
  SureBackup jobs with a virtual lab (only content scans); Cloud Connect service providers; Hyper-V
  replication, Unix (Solaris, AIX) agent and Cloud Director replication jobs; CDP proxies and policies;
  the backups inside an Application Backup Repository and Unix agent backups (Backups table).
- No plug-in platform hosts and no ESXi versions (the vCenter REST API has none either).
- Plug-in platform jobs (Nutanix AHV, Proxmox VE, HPE Morpheus VME) are not in `/jobs`. Python finds them
  in `/backups` with their repository, VMs, restore points and last run, but without state, sources,
  retention, encryption or data-flow links. Their objects are every VM found in their backups, including VMs the job no
  longer protects, so the count can be higher than the console's.
- On VBR v13 the inventory does not return VMs per host: without `--vcenter-user`, components are usually
  not placed on ESXi hosts. A vCenter whose login is rejected shows no ESXi hosts (`managedServers` lists
  only the vCenter, even with `includeNestedHosts`).
- Enterprise Manager is shown only when given with `--em` (or installed on the VBR host): the REST API does
  not expose the EM registration.
- Application Backup Repositories have no endpoint, only their server's role. A backup copy from an ABR
  names its virtual repository (`AbrVirtual`, another ID); with one ABR in the report Python links the copy
  to it and takes its name from there. With several ABRs the copy has no source link, and each ABR shows by
  its server name, without path or retention.
- Entra ID tenant backups show no restore point count (REST returns none).
- Repositories without a host of their own (object storage, dedup appliances) show as "Unknown / physical".
- VBR 13.2 adds REST endpoints (Red Hat OpenStack and Virtuozzo, storage copy jobs, Application Client
  authentication) that this version does not use yet.

**Differences between the collectors**

- The backup server is named after the host used to connect, or its DNS name when that is a short name
  or an IP. When the scanning machine's DNS (or hosts file) only knows an alias, PowerShell shows the alias;
  Python shows the full name from `serverInfo` when there is one. Placement still finds the VM by address.
- Azure Blob containers are managed servers in PowerShell only; Veeam Data Cloud Vault archive repositories
  (`VeeamDataCloudVaultArchive`) are in Python only.
- Job object locations: PowerShell shows the full inventory path, Python only the host name (vCenter /
  Hyper-V host). Object type names differ slightly (`Vapp` / `vApp`, `Virtual machine` / `Virtual Machine`
  for Hyper-V), and PowerShell lists the computers of an agent job as `Protection group`.

## Unreleased

### Added
- Both: the Jobs table shows each job's retention (for example `7 days`, `14 restore points`) and whether
  it encrypts its backups. PowerShell reads `Options.BackupStorageOptions` of `Get-VBRJob` jobs and the
  retention and storage options of the agent, backup copy, file share, Entra ID and configuration backup
  cmdlets (file backup copy jobs: `Options.NasBackupRetentionPolicy`, which holds the source job's
  retention unless the copy has its own); Python reads `retentionPolicy` and `encryption` from `/api/v1/jobs` (replicas:
  `restorePointsToKeep`) and `/api/v1/configBackup`.
- Both: Jobs table cells that the collector cannot read show "n/a" with a numbered note under the table that
  gives the reason (PowerShell: last run of tape jobs, the configuration backup and Entra ID tenant backups,
  tape retention and encryption; Python: state, sources, retention and encryption of plug-in platform jobs).
  The model gains an optional `unavailable` map per job.

### Changed
- Both: policies that the agent manages itself show "N/A" as their last result, as the VBR console does.

### Fixed
- PowerShell: repositories missing from three kinds of jobs. File backup copy jobs only carry
  `TargetRepositoryId`; agent policies that the agent manages keep their repository in
  `DestinationOptions.BackupRepository`; Veeam Vault archive repositories are returned by neither
  `Get-VBRObjectStorageRepository` nor `Get-VBRArchiveObjectStorageRepository`, so a job's repository that is
  not in the report yet is added from the job itself (as object storage when it is an archive repository).
- PowerShell: file backup copy jobs show their source job and the copy link: `Get-VBRNASBackupCopyJob`
  gives the source job's ID only, in `LinkedJobIds`.
- PowerShell: a tape job whose `Enabled` flag is off no longer shows as disabled. `Get-VBRTapeJob` uses
  the same flag for a disabled job and for one without a schedule (the console shows `<Disabled>` or
  `<Not scheduled>`), so its state shows "n/a" with a note.
- Both: Entra ID tenant and audit log backup jobs show their tenant as source and object (PowerShell:
  `Tenant` / `BackupObject.Tenant`; Python: `tenant.tenantId` / `storage.tenantId` with `/entraIdTenants`).
- Both: the object count next to a SureBackup job no longer counts its virtual lab, as the VBR console's
  Objects column.

## v1.10.0 (2026-11-05)

### Added
- PowerShell: CDP proxies (`Get-VBRCDPProxy`), drawn with the backup proxies, with their cache path and size.
- PowerShell: CDP policies (`Get-VBRCDPPolicy`), drawn as source host → CDP proxies → target host, and Cloud
  Director replication jobs that `Get-VBRJob` does not return (`Get-VBRvCDReplicaJob`, listed only).
- Both: the configuration backup (`Get-VBRConfigurationBackupJob`, REST `/api/v1/configBackup`) is listed in
  the Jobs table; its target repository and encryption show on the backup server card.
- Both: file backup copy jobs are linked from their source job's repository to their target.
- Both: the Jobs table shows each job's last run and last result (Success / Warning / Failed), as the VBR
  console's Jobs view. PowerShell reads them with `FindLastSession()` on `Get-VBRJob` jobs and the session
  cmdlets of agent, file share, SureBackup and Entra ID jobs (tape jobs and the configuration backup: their
  `LastResult`); Python from `/api/v1/jobs/states`, and `/api/v1/sessions` for plug-in platform jobs and the
  configuration backup.
- Both: a Backups table, as the VBR console's Backups view: one row per backup (storage snapshots and
  backups whose job no longer exists included; backups without restore points left out by PowerShell) with
  its job, repository, platform, creation time, restore points, last backup (the newest restore point; Python
  reads `/api/v1/restorePoints` for it) and size on disk, and the same per object when expanded (a VM backed
  up as two objects, for example after it was registered again, has two rows). PowerShell reads them with
  `Get-VBRBackup` and `Get-VBRRestorePoint` (plug-in platform backups, which `Get-VBRRestorePoint` refuses,
  with `FindChildBackups()` and `GetAllChildrenStorages()`), Python from `/api/v1/backups/{id}/backupFiles`
  (one request per backup) and `/api/v1/backupObjects`. Checked against the console on VBR v13.1.
- Python: the jobs of plug-in platforms (Nutanix AHV, Proxmox VE, HPE Morpheus VME), which `/jobs` does not
  return, are found by job type or platform ID in `/backups` and list the VMs in their backups (from
  `/api/v1/backupObjects`).

### Changed
- PowerShell: Entra ID audit log backups and file backup copies, which `Get-VBRUnstructuredBackupJob` also
  returns, are no longer labeled `File backup`. They are told apart with `Get-VBREntraIDLogsBackupJob` and
  `Get-VBRNASBackupCopyJob`, and labeled `Entra ID audit log backup` and `File backup copy`, as in Python.
- Python: the `EntraIDAuditLogBackup` and `FileBackupCopy` job types get the same labels.
- PowerShell: a job object size of `0 B` (no estimate, as for plug-in platform VMs) is left empty.
- Python: proxies of type `NutanixAHV` and `PVE` are shown as "Nutanix AHV worker" and "Proxmox VE worker".
  REST 1.3-rev2 lists these types, but VBR v13.1 does not return the workers yet.

## v1.9.0 (2026-11-05)

### Added

- Both: Application Backup Repositories (VBR v13) are drawn with the repositories, on their own card
  even when the same server is also a hardened repository. PowerShell reads them with
  `Get-VBRApplicationBackupRepository` (name, host, ZFS pool / mount path, retention); Python finds their
  server through its `ApplicationBackupRepository` role in `managedServers`.
- Both: backup copies from an Application Backup Repository are linked to it. The job names the ABR's
  virtual repository (another ID), so PowerShell matches it by name, and Python links it when the report
  has one ABR.
- Both: the sources of a backup copy job also list its source repositories (for example, a copy from an
  Application Backup Repository).

### Thanks

- Thanks to **Chris Childerhose** for testing the tool, reporting that an Application Backup Repository
  on a hardened repository server showed up only as the hardened repository, and pointing to
  `Get-VBRApplicationBackupRepository`.

## v1.8.0 (2026-11-04)

### Added

- Python: asks for REST API 1.3-rev2 first (VBR v13.1), then falls back to older versions.
- Python: Hyper-V cluster member hosts (`managedServers?includeNestedHosts=true`), with their cluster in
  the details, as in PowerShell.
- Python: file shares, object storage accounts (`/inventory/unstructuredDataServers`) and Entra ID
  tenants (`/inventory/entraId/tenants`) under "Other servers", as PowerShell lists them. File share
  objects of a job now show the share as their location.
- Python: Proxmox VE and Nutanix AHV jobs, which `/jobs` does not return, are listed from their backups
  (`/backups`: name, type and repository). Their state is not known and shows as "—".
- Python: Proxmox VE / Nutanix AHV hosts, if `managedServers` returns them (the 1.3-rev2 schema defines
  `ProxmoxNode`, `ProxmoxCluster`, `NutanixCluster` and `PrismCentral`, but VBR v13.1 does not return them).

### Fixed

- Python: jobs and backup copies to a Data Domain or HPE StoreOnce repository now show it (REST
  1.3-rev2 returns deduplicating storage appliances).
- Python: Object First on VBR v13 (`S3Integrated`), Veeam Data Cloud Vault archive and the other object
  storage types of REST 1.3-rev2 were drawn as plain repositories; they are object storage now, as in
  PowerShell.

## v1.7.0 (2026-11-03)

### Added

- Both: ESXi hosts are grouped by vSphere cluster in the diagram (new `cluster` field: name and
  vCenter). Click a cluster title to collapse it into one card; with more than 12 clustered hosts, all
  clusters start collapsed.
- Both: click a SOBR card to show its tiers under it: performance extents, capacity tier and archive
  tier (new SOBR fields `capacity` and `archive`, object storage node ids).
- Both: object storage cards show their connection mode: "Direct connection", or the first gateway server
  and how many more (`Gateway: gw01 +8`); the details list all gateways and the connection mode.
  PowerShell reads them from `Get-VBRObjectStorageRepository` (`ConnectionType`, `GatewayServer`), which
  also covers Veeam Vault; Python from `account.connectionSettings`.
- Python: the SOBR capacity tier is linked to its object storage ("Capacity tier offload"), and the
  SOBR details name it, as in PowerShell.

### Fixed

- Python: VBR's own temporary repository (`/tmp/VeeamTempRepo<id>` on the appliance), which the console
  and PowerShell do not list, was drawn as a Linux repository.
- Python: when DNS (or a hosts file) only knows a short alias of the backup server (for example `vbr`),
  the full name from `serverInfo` (for example `vbr-03.corp.local`) is shown instead. The appliance's
  internal name (`vbr-1a2b3c4d`) is still not used.
- Python: an Enterprise Manager that lists this VBR by its IP address (or by `serverInfo`'s name) showed
  "Registered to this EM: No".
- Python: when the EM account sees no backup server at all (usually no EM role), "Registered to this EM"
  is left unknown instead of "No", and the details say that no backup server is visible to the account.
- Both: Hyper-V replication jobs were drawn through the VMware proxies. They now go from the source
  host to the target host (on-host proxies), or through the off-host proxies the job selects.
- Both: file share paths no longer end with a separator, and object storage paths read
  `<bucket>/<folder>` in both collectors (PowerShell left out the bucket, Python added a trailing `/`).

## v1.6.0 (2026-11-02)

### Fixed

- PowerShell: a tape server whose host could not be read was also listed as a managed server without
  a role. Its managed server of the same name is now taken as its host.
- PowerShell: object storage repositories that `Get-VBRBackupRepository` also returns (Amazon S3,
  Veeam Vault, ...) were drawn as plain repositories; they are object storage now, as in Python.
- Both: Object First (`SmartObjectS3`) is drawn as object storage.
- Python: a general-purpose proxy is named after its server, as in PowerShell, instead of the REST
  name `Backup Proxy`.

### Added

- PowerShell: SureBackup virtual labs (`Get-VBRVirtualLab`), shown with the other servers and placed
  on the ESXi / Hyper-V host they run on. SureBackup jobs list their application group (with its VMs)
  and virtual lab.
- PowerShell: tape libraries (`Get-VBRTapeLibrary`) with their tape server, drives and slots, and
  tape jobs (`Get-VBRTapeJob`, Backup to tape / File to tape) in the Jobs table, with the media pool
  as the target.
- PowerShell: Cloud Connect service providers (`Get-VBRCloudProvider`), drawn with the repositories.
  Not tested on a real provider yet (the lab has none).

### Changed

- Report: the diagram's horizontal scrollbar is always shown (Chrome, Edge, Safari), and a shade on
  the left / right edge shows that the diagram continues that way. Overlay scrollbars (macOS,
  Windows 11) used to stay hidden until you scrolled, so it was not clear that the diagram is wider.

## v1.5.0 (2026-11-02)

### Fixed

- PowerShell: run from a remote console that was already connected to VBR (for example the Veeam
  PowerShell Toolkit window), the report named the console machine as the backup server and placed
  it on that machine's host. The backup server is now the host of the active connection; this
  machine's name is only used when VBR is local.
- Both: a backup server connected by a short name (for example `vbr`) could be placed on the wrong VM,
  because a VM named `VBR.WIN.Demo` has the same first label. Components are now matched by full name
  first, then by IP address, and only then by short name. A short name or IP of the backup server is
  replaced by its DNS name when DNS has one; the name used to connect shows as "Connected as".
- PowerShell: repositories that are SOBR extents were missing (`Get-VBRBackupRepository` does not
  return them), so the SOBR showed no extent hosts and the extent's server was listed as an unused
  managed server.
- PowerShell: replica jobs listed VMs VBR expanded itself (`ExtendedChild` job objects) as included
  objects. Only the objects set in the job are listed now.
- Python: the backup server showed VBR's internal name (`serverInfo.name`, for example
  `vbr-1a2b3c4d` on the appliance) instead of the host connected to.
- Python: a "Veeam Agents" node was drawn for backups that have no job (imported or orphaned). The
  `/backups` list is now only used when `/jobs` has no agent jobs (older API versions).
- Python: replica jobs had no repository; the metadata repository is shown, as in PowerShell.

### Changed

- Python: job types read as in PowerShell (`VMware Backup`, `Hyper-V Backup`, `VMware Replication`,
  `Backup copy (Immediate)`, `Agent backup (Windows, ManagedByBackupServer)`, ...) instead of the REST
  names (`VSphereBackup`, ...).
- Python: agent, backup copy, Entra ID and SureBackup jobs show "—" as their proxies, as in
  PowerShell. Agent jobs list their protection groups as sources, backup copy and SureBackup jobs
  their source jobs.

### Added

- Python: backup copy links from the repositories of the source jobs (`sourceObjects.includes.jobs`)
  and of the listed source repositories, and replica links (source host → proxies → target ESXi
  host, or its vCenter when the host is not known), as PowerShell draws them.
- PowerShell: Entra ID tenant backup and SureBackup jobs are listed in the Jobs table (no links: they
  have no repository or proxy of their own), as Python already did. A SureBackup job without a
  virtual lab shows as `SureBackup (content scan)`; a job's application group is listed as its object.

## v1.4.0 (2026-10-30)

### Added

- Report: hovering a component shows its IP address, from the VM's guest IPs when PowerCLI or the
  vCenter REST API matched it, otherwise from DNS (both collectors). IPv4 is preferred; loopback and
  link-local addresses are skipped.

## v1.3.1 (2026-10-30)

### Added

- `docs/example.html`: the full report built from the mock data, to try without a VBR server. The
  README links an online preview of it, and its example images are rebuilt from the same data.

### Changed

- Report: the job objects column "Mode" is now "Include / Exclude" (包含 / 排除). File share masks
  show as `File mask` rows, as VBR names them, and include masks are listed too (only exclude masks
  were). Object storage jobs also list their tag masks (`Tag mask`).
- Report: the object count next to a job name leaves out File / Tag masks, which are filters, not
  protected objects.

## v1.3.0 (2026-10-30)

### Added

- Report: click a job in the Jobs table to list its protected objects (type, name, location, size,
  included / excluded) and highlight its data flow in the diagram. Both collectors fill the new
  `jobs[].objects`: PowerShell from `Get-VBRJobObject` and the `BackupObject` of agent and file
  share jobs, Python from the job details (VMs, computers, file shares, buckets, backup copy
  sources). Exclusion masks of file share jobs show as excluded rows.

### Changed

- Report: the title is now "Backup infrastructure topology" (備份基礎架構拓撲), since the report covers
  more than data movers. It follows the language switch, and the browser tab also shows the VBR
  name. Downloads are named `vbr-topology.svg` / `vbr-topology.png`.
- Report: the Jobs table now comes right after Component hosts, before the infrastructure
  inventory.

## v1.2.0 (2026-10-30)

### Added

- PowerShell: plug-in platforms (Proxmox VE, Nutanix AHV, HPE Morpheus VME) as source hosts, from
  managed servers of type `ExternalInfrastructureServer`. They get their own column and node kind
  (`ext_host`) in the report. An unknown platform ID shows as "Plug-in platform".
- PowerShell: data flow for plug-in platform jobs (Proxmox VE, Nutanix AHV, HPE Morpheus VME), from the
  source host straight to the repository. A source that is not a registered plug-in host, such as a
  Proxmox cluster name, gets inferred (dashed) links from every host of that platform.
- PowerShell: vCenter and ESXi product, version and build (from `Get-VBRServer`, no PowerCLI needed),
  plus a warning when the ESXi hosts run different versions.
- Python: vCenter product, version and build with `--vcenter-user` (`/api/appliance/system/version`).

### Fixed

- PowerShell: Nutanix AHV jobs were treated as Hyper-V jobs ("AHV" matched "Hv"); a source that was
  not a managed server then showed up as a made-up Hyper-V host.
- PowerShell: a relative `-OutDir` or `-Template` failed with "Could not find a part of the path",
  because .NET file calls resolve it against the Veeam Console folder, not the current location.

## v1.1.0 (2026-10-30)

### Added

- PowerShell: `-VCenterCredentialMap` to give each vCenter its own credentials.
- PowerShell and Python: when a vCenter rejects the login, ask once more for that vCenter's
  credentials, since vCenters often use different accounts. No prompt when the credentials come
  from `-VCenterCredentialMap`, or when Python runs without a terminal.

### Changed

- PowerShell: clearer Hyper-V warnings. A WMI failure now says to check that the host is online and
  that its credentials in VBR are valid; a cluster failure says to check the cluster service or
  remove the stale cluster from VBR. Both have Traditional Chinese translations in the report.

### Fixed

- PowerShell: `-UsePowerCLI` crashed with "You cannot call a method on a null-valued expression"
  when vCenter returned VMs without a host (disconnected host, orphaned VM). Such VMs are now
  skipped, and the console shows how many.

## v1.0.0 (2026-10-28)

First release.

### Added

- PowerShell collector `Get-VBRTopology.ps1` (Veeam PowerShell module, VBR v12+)
  - Enterprise Manager and Veeam ONE detection; `-EnterpriseManager` as a manual fallback
  - ESXi placement through VMware PowerCLI (`-UsePowerCLI`; asks for the vCenter login) or the
    Veeam inventory
  - Tape servers, replica jobs, SOBR capacity-tier offload
- Python collector `vbr_topology.py` (VBR REST API, standard library only)
  - Enterprise Manager with `--em`, verified against the EM REST API
  - ESXi hosts and placement through the vCenter REST API (`--vcenter-user`), falling back to the
    VBR inventory
  - `--from-raw` to re-render a saved scan offline
- Shared report `template.html`
  - Architecture diagram: data movers, job data flow, the ESXi host of each component, repository
    capacity and free space
  - Tables: component hosts, infrastructure inventory, jobs
  - Traditional Chinese / English switch; export to SVG, PNG and JSON
- Manual component → host map (`-PlacementCsv` / `--placement-csv`)
- One output folder per run (`out/<vbr>_<time>/`)
- Offline mocks in `test/`
