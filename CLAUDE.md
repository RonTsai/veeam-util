# veeam-util: notes for Claude

Utilities for Veeam Backup & Replication. Author: Ron Tsai @Veeam Taiwan.
Code, comments, console output and docs are in English.
The maintainer's personal working rules and lab notes are in `CLAUDE.local.md` (git-ignored), when present.

## Rules for every change

- **Never commit real environment data**: host names, IPs, user names, passwords, or scan output
  (`out/`, `vbr_raw.json`). Use `corp.local` style examples. Before committing, grep for anything
  that looks like a real host or IP.
- **Lab credentials live only in local, git-ignored files** (`*.local.md`, `*.local.ps1`,
  `*.local.env`). Never copy them into tracked files, commit messages or reports. If a credential is
  needed, ask the user, or read it from such a file or from an environment variable
  (`VBR_PASSWORD`, `EM_PASSWORD`, `VCENTER_PASSWORD`).
- Record changes under "Unreleased" in the tool's CHANGELOG. Releases are tagged `<tool>-vX.Y.Z`
  (for example `vbr-topology-v1.0.0`) and marked pre-release; only the maintainer publishes them.

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
    inSobr, extents, capacity, archive, placeLabel, cluster` (`cluster`: `{name, vcenter}` on ESXi hosts;
    `capacity` / `archive`: a SOBR's object storage node ids)
  - `kind` is one of `backup, em, vone, agent, hv_host, vi_host, ext_host, proxy, repo, sobr, object, server`
    (`ext_host`: plug-in platforms such as Proxmox VE; PowerShell only, the REST API does not return them)
  - `links[]`: `source, target, kind (data | auto | copy | inferred | gateway), jobs` (`gateway`: a gateway
    server's proxy card to a repository whose data goes through it, no jobs)
  - `jobs[]`: `name, type, disabled, repository, sources, proxies, objects`, optionally `typeDetail, target, lastRun,
    lastResult, retention, encrypted, unavailable` (`type`: the VBR console's Jobs view name; `typeDetail`: what
    that name leaves out, such as a backup copy's mode; `target`: a replica's or CDP policy's target host, a
    SureBackup job's virtual lab, shown instead of `repository`; `lastRun`: `yyyy-MM-dd HH:mm`;
    `lastResult`: `Success | Warning | Failed`, `Running` for a job running at scan time, `N/A` for policies the
    agent manages; `retention`: `7 days`, `14 restore points`, `1 year`; `encrypted`: bool;
    `unavailable`: `{field: note code}` for cells the collector cannot read, shown as "n/a" with the footnote
    `note_<code>` from `template.html`'s `I18N`)
  - `backups[]`: `name, job, created, repository, platform`, optionally `restorePoints, lastBackup, onDisk`,
    and `objects[]` (`name`, optionally `restorePoints, lastBackup, onDisk`), as the VBR console's Backups view
    (`created` / `lastBackup`: `yyyy-MM-dd HH:mm`; `onDisk`: bytes)
    (`objects[]`: `name, type, location, size, excluded`, optionally `unavailable` as for jobs (`location`, `size`),
    the job's protected objects)
  - `warnings[]`, `vbr`, `lang`
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

### Example report and README images

`vbr-topology/docs/example.html` and `vbr-topology/docs/images/*.png` are built from the mocks. When a
change alters what the report shows (`template.html`, the model, the mocks), rebuild them in the same
change, so the README matches the code:

```powershell
cd vbr-topology
. ./test/Mock-VeeamCmdlets.ps1; . ./test/Mock-PowerCLI.ps1
$c = New-Object PSCredential("ro@vsphere.local", (ConvertTo-SecureString "x" -AsPlainText -Force))
./Get-VBRTopology.ps1 -Server vbr01.corp.local -OutDir ./test/out_ps -NoTimestamp -UsePowerCLI -VCenterCredential $c -Language en
Copy-Item ./test/out_ps/topology.html ./docs/example.html
```

- `report-en.png`: the diagram SVG only, at 2x (as the report's Download PNG).
- `report-jobs-en.png`: the Jobs heading, hint, table (with `VMware-Prod-Daily` expanded) and notes, at 2x.

To take them, copy the report to a scratch folder, append a script that keeps only that part of the
page (and clicks the job), then use headless Chrome:
`--headless=new --hide-scrollbars --force-device-scale-factor=2 --window-size=<W>,<H> --screenshot=...`
(get W and H from `--dump-dom` with the script writing them into `<title>`). Look at both images, and
grep `example.html` for real names, IPs and local paths before committing.

The mocks follow the documented API shapes, but real responses can differ. The code is tested on a
real lab (VBR v13.1, vCenter 8.0.3, ESXi 7.0.3 and 8.0.3). When something fails on a real server, ask
for the console output or the relevant part of `vbr_raw.json`, with names masked.

## Open items

See "Known limitations" in `vbr-topology/CHANGELOG.md`.
