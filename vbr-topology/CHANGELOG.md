# Changelog: vbr-topology

## Unreleased

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

- Tested in one lab environment (VBR v13.1, vCenter 7) and against the offline mocks only.
- Python does not list tape servers yet; the REST endpoint for them still needs to be confirmed.
- On VBR v13 REST, the inventory does not return VMs per host. Without `--vcenter-user`, Python
  usually cannot place components on ESXi hosts.
- Without PowerCLI or `--vcenter-user`, components are matched by VM name only. Proxies registered
  by IP, and VMs whose name differs from their hostname, show as "Physical / unknown host".
- PowerShell detects Enterprise Manager through an undocumented VBR API
  (`SBackupOptions.GetEnterpriseServerInfo`), which may change between versions.
- Hyper-V placement (`Find-VBRHvEntity`) has not been tested on a real Hyper-V environment.
