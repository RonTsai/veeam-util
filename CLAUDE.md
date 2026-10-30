# veeam-util: notes for Claude

Utilities for Veeam Backup & Replication. Author: Ron Tsai @Veeam Taiwan.
Reply to the user in Traditional Chinese. Code, comments, console output and docs are in English.

## Working agreements

- **Ask before changing code.** Explain the proposed change and wait for approval.
- **Show the commit plan before pushing**: the files, the commit message and any README changes.
  Push only after the user says so.
- **Never commit real environment data**: host names, IPs, user names, passwords, or scan output
  (`out/`, `vbr_raw.json`). Use `corp.local` style examples. Before committing, grep for anything
  that looks like a real host or IP.
- **Lab credentials live only in local, git-ignored files** (`*.local.md`, `*.local.ps1`,
  `*.local.env`). Never copy them into tracked files, commit messages or reports. If a credential is
  needed, ask the user, or read it from such a file or from an environment variable
  (`VBR_PASSWORD`, `EM_PASSWORD`, `VCENTER_PASSWORD`).
- Tags are `<tool>-vX.Y.Z` (for example `vbr-topology-v1.0.0`). Tag pushes are blocked from cloud
  sessions, so the user creates tags and releases in the GitHub UI.

## Layout

- `vbr-topology/`: VBR architecture scanner (see its README and CHANGELOG)
  - `Get-VBRTopology.ps1`: PowerShell collector (Veeam module, optional PowerCLI)
  - `vbr_topology.py`: Python collector (VBR REST API, optional vCenter REST)
  - `template.html`: shared report template; both collectors embed their model into it
  - `test/`: offline mocks; `sample_raw.json`: demo data for `--from-raw`

## vbr-topology design rules

- **Read-only.** Only `Get-*` / `Find-*` cmdlets, and only REST reads (plus login / logout, and the
  read-only inventory browser POST). Never add anything that changes VBR or vCenter.
- **Keep the two collectors in parity.** Both produce the same model:
  - `nodes[]`: `id, kind, name, sub, badges, details`, optionally `placement, runsOn, usage,
    inSobr, extents, placeLabel`
  - `kind` is one of `backup, em, vone, agent, hv_host, vi_host, ext_host, proxy, repo, sobr, object, server`
    (`ext_host`: plug-in platforms such as Proxmox VE; PowerShell only, the REST API does not return them)
  - `links[]`: `source, target, kind (data | auto | copy | inferred), jobs`
  - `jobs[]`, `warnings[]`, `vbr`, `lang`
- **i18n.** Collectors write English only. All on-screen text lives in `template.html`:
  `I18N` for UI strings, `DATA_ZH` / `DATA_ZH_RULES` for collector text. Whenever a collector
  emits new display text, add its Traditional Chinese translation there.
- **Python: standard library only**, Python 3.8+.
- **PowerShell: must run on Windows PowerShell 5.1.** No `??`, no ternary operator, no
  `?.`. Save `.ps1` files as UTF-8 with BOM.
- One cmdlet or endpoint failing must not stop the scan: catch the error, add a warning, carry on.
- Each run writes to `out/<vbr>_<time>/` unless `-NoTimestamp` / `--no-timestamp` is given.

## Testing

PowerShell, with fake Veeam cmdlets (works with `pwsh` on Linux too):

```powershell
cd vbr-topology
. ./test/Mock-VeeamCmdlets.ps1; ./Get-VBRTopology.ps1 -Server vbr01.corp.local -OutDir ./test/out_ps -NoTimestamp

# With fake PowerCLI as well (a VM without a host; the vCenter password "bad" is rejected)
. ./test/Mock-PowerCLI.ps1; ./Get-VBRTopology.ps1 -Server vbr01.corp.local -OutDir ./test/out_ps -NoTimestamp -UsePowerCLI
```

Python, offline and against the HTTPS mocks of the VBR, EM and vCenter REST APIs:

```bash
cd vbr-topology
python3 vbr_topology.py --from-raw sample_raw.json --out /tmp/out --no-timestamp
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/key.pem -out /tmp/cert.pem -days 2 -subj /CN=localhost
python3 test/mock_vbr_rest.py /tmp/cert.pem /tmp/key.pem 19419 19398 19443 &
EM_REST_PORT=19398 VBR_PASSWORD=x VCENTER_PASSWORD=x python3 vbr_topology.py --host localhost --port 19419 \
  --user admin --insecure --em localhost --vcenter-user ro@vsphere.local --vcenter localhost:19443 --out /tmp/out
```

Mock env switches: `MOCK_IP_PROXY`, `MOCK_VC_OLD`, `MOCK_EMPTY_PARENT`, `MOCK_NO_LEGACY`, `MOCK_NO_BROWSER`.
Check the report in both languages (`topology.html?lang=en` / `?lang=zh`) with Playwright.

The mocks follow the documented API shapes, but real responses can differ. The user tests on a
real lab (VBR v13.1, vCenter 7). When something fails there, ask for the console output or the
relevant part of `vbr_raw.json`, with names masked.

## Open items

See "Known limitations" in `vbr-topology/CHANGELOG.md`.
