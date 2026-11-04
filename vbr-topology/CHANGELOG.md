# Changelog: vbr-topology

## Unreleased

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

### Known limitations

- Tested in one lab environment (VBR v13.1, vCenter 8.0.3, ESXi 7.0.3 and 8.0.3) and against the
  offline mocks only.
- Python does not list tape servers, tape libraries, tape jobs, SureBackup virtual labs or Cloud
  Connect service providers: the REST API (1.3-rev2) has no endpoints for them.
- On VBR v13 REST, the inventory does not return VMs per host. Without `--vcenter-user`, Python
  usually cannot place components on ESXi hosts.
- Without PowerCLI or `--vcenter-user`, components are matched by VM name only. Proxies registered
  by IP, and VMs whose name differs from their hostname, show as "Physical / unknown host".
- PowerShell detects Enterprise Manager through an undocumented VBR API
  (`SBackupOptions.GetEnterpriseServerInfo`), which may change between versions.
- Some PowerShell data comes from .NET methods and internal classes that Veeam does not support (see
  the [PowerShell FAQ](https://forums.veeam.com/viewtopic.php?f=26&t=89480) on the R&D Forums):
  `GetHost()` (proxy and repository hosts), `GetContainer()` (repository capacity and free space),
  `GetActualGateways()` (gateways), `GetTargetRepository()` and `GetProxy()` (job targets and proxies),
  `GetPhysicalHost()` (plug-in platform type) and `Info.Info` (vCenter / ESXi versions). Each call is
  wrapped, so a change in a VBR update leaves that detail empty instead of stopping the scan.
- Hyper-V placement (`Find-VBRHvEntity`) has not been tested on a real Hyper-V environment.
- The proxies (workers) of plug-in platforms (Proxmox VE, Nutanix AHV, HPE Morpheus VME) are not
  exposed through PowerShell (`GetChilds()` / `GetSubHosts()` return nothing) or the REST API, so the
  report does not show them.
- Python shows neither plug-in platform hosts nor ESXi versions: the VBR REST API (v13.1) does not return
  them, and the vCenter REST API has no ESXi version.
- The plug-in platform IDs were taken from one lab; other plug-in versions may use other IDs.
- The VBR REST API does not list plug-in platform jobs (Proxmox VE, Nutanix AHV, HPE Morpheus VME) in
  `/jobs`. Python lists Proxmox VE and Nutanix AHV jobs from `/backups` (name and repository only: no
  state, sources, objects or links); HPE Morpheus VME jobs are not shown.
- Job object locations differ by collector: PowerShell shows the full inventory path, Python only
  the host name (vCenter / Hyper-V host).
- The VBR REST API (v13.1) does not list Hyper-V replication jobs, Unix (Solaris, AIX) agent jobs or
  SureBackup jobs with a virtual lab (only content scans), so the Python report does not show them.
- Python only shows an Enterprise Manager given with `--em` (or installed on the VBR host): the REST
  API does not expose the EM registration.
- Python shows no ESXi hosts of a vCenter whose login was rejected: REST `managedServers` lists only the
  vCenter, even with `includeNestedHosts`.
- Python does not show Azure Blob containers, which PowerShell lists as managed servers. It lists Veeam
  Data Cloud Vault archive repositories (`VeeamDataCloudVaultArchive`), which PowerShell does not.
- The backup server is named after the host used to connect, or its DNS name when that is a short name
  or an IP. When DNS (or the hosts file) of the scanning machine only knows an alias, PowerShell shows
  the alias (it has no other source for the name); Python shows the full name from `serverInfo` when
  there is one. Placement still finds the VM by the address.
- Repositories without a host of their own (object storage, dedup appliances) are placed on their
  gateway server by PowerShell (often the VBR server); Python shows them as "Unknown / physical".
- Both collectors label object storage backup jobs `File backup`, as `Get-VBRUnstructuredBackupJob`
  does not tell them apart.
- Object type names differ slightly by collector (`Vapp` / `vApp`, `Virtual machine` / `Virtual
  Machine` for Hyper-V), and PowerShell lists the computers of an agent job as `Protection group`.
- Entra ID tenant backup jobs have no enabled / disabled state in PowerShell (only `EnableSchedule`),
  so they always show as enabled.
