# Changelog: vbr-topology

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
- Python does not list tape servers yet; the REST endpoint for them still needs to be confirmed.
- On VBR v13 REST, the inventory does not return VMs per host. Without `--vcenter-user`, Python
  usually cannot place components on ESXi hosts.
- Without PowerCLI or `--vcenter-user`, components are matched by VM name only. Proxies registered
  by IP, and VMs whose name differs from their hostname, show as "Physical / unknown host".
- PowerShell detects Enterprise Manager through an undocumented VBR API
  (`SBackupOptions.GetEnterpriseServerInfo`), which may change between versions.
- Hyper-V placement (`Find-VBRHvEntity`) has not been tested on a real Hyper-V environment.
- The proxies (workers) of plug-in platforms (Proxmox VE, Nutanix AHV, HPE Morpheus VME) are not
  exposed through PowerShell (`GetChilds()` / `GetSubHosts()` return nothing) or the REST API, so the
  report does not show them.
- Python shows neither plug-in platforms nor ESXi versions: the VBR REST API does not return them, and
  the vCenter REST API has no ESXi version.
- The plug-in platform IDs were taken from one lab; other plug-in versions may use other IDs.
- The VBR REST API does not list plug-in platform jobs (Proxmox VE, Nutanix AHV, HPE Morpheus VME),
  so the Python report has neither these jobs nor their objects.
- Job object locations differ by collector: PowerShell shows the full inventory path, Python only
  the host name (vCenter / Hyper-V host).
