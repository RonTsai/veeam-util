#!/usr/bin/env python3
"""
Veeam Backup & Replication topology scanner.

Logs in to the VBR REST API (default https://<vbr>:9419), scans the backup
infrastructure (managed servers, hypervisors, proxies, repositories, SOBRs,
WAN accelerators, agent protection groups, jobs), works out the data flow,
finds which ESXi host each component runs on, and renders an interactive
architecture diagram (HTML).

Usage:
  # Live scan
  python3 vbr_topology.py --host vbr01.corp.local --user 'CORP\\veeam-admin' --insecure

  # Add an Enterprise Manager (VBR REST API does not expose the EM registration)
  python3 vbr_topology.py --host vbr01 --user admin --insecure --em em01.corp.local

  # Find the ESXi host of each component by querying vCenter directly (most accurate)
  python3 vbr_topology.py --host vbr01 --user admin --insecure --vcenter-user readonly@vsphere.local

  # Re-render from a previous scan (offline)
  python3 vbr_topology.py --from-raw out/<run>/vbr_raw.json

Standard library only, no packages to install. VBR is only read from: every
call is a GET, except the inventory browser query (a read-only POST) and login.
vCenter (optional) is only read as well: hosts, VMs and guest identity.
"""

import argparse
import base64
import csv
import datetime as dt
import getpass
import ipaddress
import json
import os
import re
import socket
import ssl
from concurrent.futures import ThreadPoolExecutor
import sys
import urllib.error
import urllib.parse
import urllib.request

# Tried newest to oldest; the first one the server accepts wins.
# v13 -> 1.3-revX, v12.3 -> 1.2-revX, v12.1/12.2 -> 1.1-rev1/rev2, v12.0 -> 1.1-rev0
API_VERSIONS = ["1.3-rev2", "1.3-rev1", "1.3-rev0", "1.2-rev1", "1.2-rev0",
                "1.1-rev2", "1.1-rev1", "1.1-rev0", "1.0-rev2", "1.0-rev1"]

# Endpoints to collect: key -> (path, paginated)
ENDPOINTS = {
    "serverInfo":           ("/api/v1/serverInfo", False),
    # includeNestedHosts: also the hosts inside a Hyper-V cluster (or vCenter), as PowerShell lists them
    "managedServers":       ("/api/v1/backupInfrastructure/managedServers?includeNestedHosts=true", True),
    "proxies":              ("/api/v1/backupInfrastructure/proxies", True),
    "repositories":         ("/api/v1/backupInfrastructure/repositories", True),
    "repositoryStates":     ("/api/v1/backupInfrastructure/repositories/states", True),
    "scaleOutRepositories": ("/api/v1/backupInfrastructure/scaleOutRepositories", True),
    "wanAccelerators":      ("/api/v1/backupInfrastructure/wanAccelerators", True),
    "protectionGroups":     ("/api/v1/agents/protectionGroups", True),
    "jobs":                 ("/api/v1/jobs", True),
    "backups":              ("/api/v1/backups", True),
    # Managed servers that are not hosts (file shares, object storage accounts, Entra ID tenants)
    "unstructuredDataServers": ("/api/v1/inventory/unstructuredDataServers", True),
    "entraIdTenants":       ("/api/v1/inventory/entraId/tenants", True),
    "configBackup":         ("/api/v1/configBackup", False),
    # Last run and result of each job
    "jobStates":            ("/api/v1/jobs/states", True),
    # Backed-up objects (VM names of plug-in platform jobs, which /jobs does not return)
    "backupObjects":        ("/api/v1/backupObjects", True),
}

EM_REST_PORT = int(os.environ.get("EM_REST_PORT", "9398"))  # override for testing only
EM_NONE_VISIBLE = "None visible to this account (check its Enterprise Manager role)"


# --------------------------------------------------------------------------
# REST client
# --------------------------------------------------------------------------

def make_ssl_context(insecure, ca_bundle):
    if insecure:
        return ssl._create_unverified_context()
    return ssl.create_default_context(cafile=ca_bundle)


class VbrClient:
    def __init__(self, host, port=9419, insecure=False, ca_bundle=None, timeout=60):
        self.base = f"https://{host}:{port}"
        self.timeout = timeout
        self.ctx = make_ssl_context(insecure, ca_bundle)
        self.token = None
        self.api_version = None

    def _request(self, method, path, data=None, headers=None):
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Accept", "application/json")
        if self.api_version:
            req.add_header("x-api-version", self.api_version)
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
            body = r.read()
            return json.loads(body) if body else None

    def login(self, user, password, api_version="auto"):
        versions = API_VERSIONS if api_version == "auto" else [api_version]
        form = urllib.parse.urlencode({
            "grant_type": "password", "username": user, "password": password,
        }).encode()
        last_err = None
        for v in versions:
            self.api_version = v
            try:
                res = self._request("POST", "/api/oauth2/token", data=form, headers={
                    "Content-Type": "application/x-www-form-urlencoded"})
                self.token = res["access_token"]
                return v
            except urllib.error.HTTPError as e:
                detail = e.read().decode(errors="replace")[:300]
                last_err = f"HTTP {e.code}: {detail}"
                if e.code == 401:
                    raise SystemExit(f"Login failed (wrong user name or password): {detail}")
                # 400 usually means this x-api-version is not supported; try the next one
        raise SystemExit(f"Could not log in to the VBR REST API: {last_err}")

    def logout(self):
        try:
            self._request("POST", "/api/oauth2/logout")
        except Exception:
            pass

    def get_all(self, path, paged=True, limit=500):
        if not paged:
            return self._request("GET", path)
        items, skip = [], 0
        while True:
            sep = "&" if "?" in path else "?"
            res = self._request("GET", f"{path}{sep}skip={skip}&limit={limit}")
            data = res.get("data", []) if isinstance(res, dict) else (res or [])
            items.extend(data)
            total = (res.get("pagination") or {}).get("total") if isinstance(res, dict) else None
            skip += len(data)
            if not data or len(data) < limit or (total is not None and skip >= total):
                return items

    def post_all(self, path, body, limit=500):
        """Paginated POST query (used by the inventory browser)."""
        items, skip = [], 0
        while True:
            spec = dict(body, pagination={"skip": skip, "limit": limit})
            res = self._request("POST", path, data=json.dumps(spec).encode(),
                                headers={"Content-Type": "application/json"})
            data = res.get("data", []) if isinstance(res, dict) else (res or [])
            items.extend(data)
            total = (res.get("pagination") or {}).get("total") if isinstance(res, dict) else None
            skip += len(data)
            if not data or len(data) < limit or (total is not None and skip >= total):
                return items


def collect(client):
    raw = {"_meta": {"base": client.base, "apiVersion": client.api_version,
                     "collectedAt": dt.datetime.now().isoformat(timespec="seconds")},
           "_errors": {}}
    for key, (path, paged) in ENDPOINTS.items():
        try:
            raw[key] = client.get_all(path, paged)
            n = len(raw[key]) if isinstance(raw[key], list) else 1
            print(f"  [OK]   {key:<22} {n}")
        except urllib.error.HTTPError as e:
            raw["_errors"][key] = f"HTTP {e.code}"
            print(f"  [skip] {key:<22} HTTP {e.code} (not supported by this version or account)")
        except Exception as e:  # noqa: BLE001 - one failing endpoint must not stop the scan
            raw["_errors"][key] = str(e)
            print(f"  [skip] {key:<22} {e}")
    # Job details (the list response does not always include storage/proxy settings)
    details = {}
    for job in raw.get("jobs") or []:
        if "storage" in job or "virtualMachines" in job:
            continue
        try:
            details[job["id"]] = client._request("GET", f"/api/v1/jobs/{job['id']}")
        except Exception:
            pass
    if details:
        raw["jobs"] = [details.get(j["id"], j) for j in raw["jobs"]]
    collect_backup_files(client, raw)
    collect_last_sessions(client, raw)
    raw["inventory"] = collect_inventory(client, raw)
    return raw


def collect_backup_files(client, raw):
    """
    The backup files of each backup (one request per backup), for the restore points, latest backup
    and size on disk of each job. Only the fields the report uses are kept.
    """
    backups = [b for b in raw.get("backups") or [] if b.get("id")]
    if not backups:
        return

    def files_of(b):
        try:
            return b["id"], [{k: f.get(k) for k in ("id", "objectIds", "restorePointIds", "backupSize", "creationTime")}
                             for f in client.get_all(f"/api/v1/backups/{b['id']}/backupFiles")]
        except Exception as e:  # noqa: BLE001 - one backup failing must not stop the scan
            return b["id"], e

    files, errors = {}, []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for bid, res in pool.map(files_of, backups):
            if isinstance(res, Exception):
                errors.append(res)
            else:
                files[bid] = res
    raw["backupFiles"] = files
    print(f"  [OK]   {'backupFiles':<22} {sum(len(f) for f in files.values())} in {len(files)} backups")
    # Restore point times: the console shows an object's newest restore point, not its newest file
    try:
        raw["restorePointTimes"] = {p["id"]: p.get("creationTime") for p in client.get_all("/api/v1/restorePoints")
                                    if p.get("id")}
        print(f"  [OK]   {'restorePoints':<22} {len(raw['restorePointTimes'])}")
    except Exception as e:  # noqa: BLE001
        raw["_errors"]["restorePoints"] = str(e)
        print(f"  [skip] {'restorePoints':<22} {e}")
    if errors:
        raw["_errors"]["backupFiles"] = f"{len(errors)} of {len(backups)} backups failed: {errors[-1]}"
        print(f"  [skip] {'backupFiles':<22} {raw['_errors']['backupFiles']}")


def _ts(v):
    """ISO time -> 'yyyy-MM-dd HH:mm' (server time, as given)."""
    return v[:16].replace("T", " ") if v else None


def _parse_time(v):
    """ISO time -> aware datetime (UTC when no offset is given), None when it cannot be read. Python 3.8's
    fromisoformat needs 3 or 6 fraction digits and no "Z", so the fraction is dropped."""
    if not v:
        return None
    try:
        t = dt.datetime.fromisoformat(re.sub(r"\.\d+", "", str(v)).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def backup_job_id(b, job_ids_by_name, known_ids):
    """The job of a backup: its jobId, or the job of the same name when jobId is not a known job (a
    backup copy's backups can name another id)."""
    jid = b.get("jobId")
    if jid not in known_ids and b.get("name") in job_ids_by_name:
        return job_ids_by_name[b["name"]]
    return jid


def collect_last_sessions(client, raw):
    """
    The last session of the jobs /jobs/states does not cover (plug-in platform jobs, found in /backups)
    and of the configuration backup: one request each, newest session first.
    """
    known = {x.get("id") for x in raw.get("jobStates") or []} | {j.get("id") for j in raw.get("jobs") or []}
    wanted = {b.get("jobId") for b in raw.get("backups") or [] if b.get("jobId") and b.get("jobId") not in known}
    queries = {jid: f"jobIdFilter={jid}" for jid in wanted}
    if raw.get("configBackup"):
        queries["configBackup"] = "typeFilter=ConfigurationBackup"
    if not queries:
        return

    def last(item):
        key, q = item
        try:
            res = client._request("GET", f"/api/v1/sessions?{q}&orderColumn=CreationTime&orderAsc=false&limit=1")
            s = (res.get("data") or [None])[0] if isinstance(res, dict) else None
        except Exception:  # noqa: BLE001 - the job just shows no last run
            return key, None
        if not s:
            return key, None
        r = s.get("result")
        return key, {"lastRun": _ts(s.get("creationTime")), "lastResult": r.get("result") if isinstance(r, dict) else r}

    with ThreadPoolExecutor(max_workers=8) as pool:
        raw["lastSessions"] = {k: v for k, v in pool.map(last, queries.items()) if v}
    print(f"  [OK]   {'last sessions':<22} {len(raw['lastSessions'])}")


def backup_stats(raw):
    """
    Per backup, its objects as the VBR console's Backups view lists them: backup id -> {object key:
    {"name", "points": restore point ids, "count": restore points when no files say, "last": newest file
    time, "files": {file id: size}}}. One VM can be several objects (for example after it was registered
    again); each is its own row, as in the console. Objects come from the backup files; objects without
    files (file shares, object storage, Entra ID) take their restore point count from /backupObjects.
    """
    if "backupFiles" not in raw:
        return {}
    point_times = raw.get("restorePointTimes") or {}
    object_list = [o for o in raw.get("backupObjects") or [] if o.get("id")]
    objects = {o["id"]: o for o in object_list}
    # The console's count of an object is /backupObjects' restorePointsCount. Its backupId names a child
    # backup that /backups does not list, so it is used only when the object is in one backup and has one
    # entry; otherwise the restore points are counted from the files (a vApp's files hold all its VMs)
    entries, in_backups = {}, {}
    for o in object_list:
        entries[o["id"]] = entries.get(o["id"], 0) + 1
    for bid, fs in (raw["backupFiles"] or {}).items():
        for f in fs or []:
            for oid in f.get("objectIds") or []:
                in_backups.setdefault(oid, set()).add(bid)
    per_backup = {}
    for b in raw.get("backups") or []:
        objs = per_backup.setdefault(b.get("id"), {})
        for i, f in enumerate((raw["backupFiles"] or {}).get(b.get("id")) or []):
            fid = f.get("id") or f"{b.get('id')}:{i}"
            for oid in f.get("objectIds") or [None]:
                o = objs.setdefault(oid or "", {"name": (objects.get(oid) or {}).get("name") or oid or "",
                                                "points": set(), "count": None, "last": None, "files": {}})
                o["points"].update(f.get("restorePointIds") or [])
                # The newest restore point (the file's time when /restorePoints was not read)
                for t in [point_times.get(p) for p in f.get("restorePointIds") or []] or [None]:
                    t = t or f.get("creationTime")
                    if t and (not o["last"] or t > o["last"]):
                        o["last"] = t
                o["files"][fid] = f.get("backupSize") or 0
        for oid, o in objs.items():
            e = objects.get(oid) or {}
            if entries.get(oid) == 1 and len(in_backups.get(oid, ())) == 1 and e.get("restorePointsCount") is not None:
                o["count"] = e["restorePointsCount"]
        for e in object_list:
            if e.get("backupId") == b.get("id") and e["id"] not in objs and e.get("restorePointsCount") is not None:
                objs[e["id"]] = {"name": e.get("name") or e["id"], "points": set(), "count": e["restorePointsCount"],
                                 "last": None, "files": {}}
    return per_backup


def backup_totals(objs):
    """{restorePoints, lastBackup, onDisk} of objects from backup_stats: the most restore points of one
    object, the newest file and the size of all files (each counted once)."""
    files = {}
    for o in objs.values():
        files.update(o["files"])
    counts = [o["count"] if o["count"] is not None else len(o["points"]) for o in objs.values()]
    lasts = [o["last"] for o in objs.values() if o["last"]]
    return {"restorePoints": max(counts, default=0) or None,
            "lastBackup": _ts(max(lasts)) if lasts else None,
            "onDisk": sum(files.values()) if files else None}


def _obj(item):
    """Inventory responses wrap the object in 'inventoryObject' in some API versions."""
    return item.get("inventoryObject", item) if isinstance(item, dict) else {}


def job_objects(j, names):
    """
    A job's protected objects for the report: VMs / containers, protection groups, file shares,
    buckets and backup copy sources. Exclusions (excluded VMs, exclusion masks) are flagged.
    `names` maps server ids to names. Disk-level settings in excludes.disks are not exclusions.
    """
    out = []

    def add(name, typ, location=None, size=None, excluded=False):
        if name:
            # "VirtualMachine" -> "Virtual Machine", as PowerShell's TypeDisplayName reads ("vApp" stays)
            typ = re.sub(r"(?<=[a-z]{2})(?=[A-Z])", " ", typ or "")
            out.append({"name": name, "type": typ, "location": location or "", "size": size or "",
                        "excluded": excluded})

    vms = j.get("virtualMachines") or {}
    for inc in vms.get("includes") or []:
        o = _obj(inc)
        add(o.get("name"), o.get("type"), o.get("hostName"), o.get("size"))
    for exc in (vms.get("excludes") or {}).get("vms") or []:
        o = _obj(exc)
        add(o.get("name"), o.get("type"), o.get("hostName"), o.get("size"), True)
    for c in j.get("computers") or []:
        add(c.get("name"), "Protection group" if c.get("type") == "ProtectionGroup" else c.get("type"), c.get("path"))
    # Include / exclude masks, as VBR calls them: File masks, plus tag masks for buckets
    masks = (("inclusionMask", "File mask", False), ("inclusionPathMask", "File mask", False),
             ("exclusionMask", "File mask", True), ("exclusionPathMask", "File mask", True),
             ("inclusionTagMask", "Tag mask", False), ("exclusionTagMask", "Tag mask", True))
    for o in j.get("objects") or []:
        if "objectStorageServerId" in o:
            path = "/".join(x.strip("/") for x in (o.get("container"), o.get("path")) if x and x != "/")
            add(path, "Object storage", names.get(o.get("objectStorageServerId")))
        else:
            path = (o.get("path") or "").rstrip("\\/") or o.get("path")   # no trailing backslash or slash, as PowerShell shows it
            add(path, "File share", names.get(o.get("fileServerId")))
        for key, typ, excluded in masks:
            for m in o.get(key) or []:
                if isinstance(m, dict):   # tag masks may come as {name, value}
                    m = "=".join(str(x) for x in (m.get("name"), m.get("value")) if x) or json.dumps(m)
                add(m, typ, path, excluded=excluded)
    src = j.get("sourceObjects") or {}
    for key, typ in (("jobs", "Job"), ("repositories", "Repository"), ("backups", "Backup")):
        for x in (src.get("includes") or {}).get(key) or []:
            add(_obj(x).get("name"), typ)
    for key, typ in (("jobs", "Job"), ("objects", "Object")):
        for x in (src.get("excludes") or {}).get(key) or []:
            add(_obj(x).get("name"), typ, excluded=True)
    return out


def collect_inventory(client, raw):
    """
    Collect VM -> ESXi host placement from the vSphere inventory VBR already has.

    Method A (legacy browser, deprecated since 1.1-rev1 but still served):
      list the hosts, then list VMs per host with parentContainerNameFilter.
    If that yields no VMs (in vSphere, a VM's container is usually a resource pool or
    cluster, not the host), keep the raw objects instead:
      - the legacy flat VM list, and
      - Method B, the inventory browser (POST /api/v1/inventory/{name}, 1.1-rev1+).
    The VM -> host relation is then resolved later from parent references or paths.
    """
    vi = [s for s in raw.get("managedServers") or [] if s.get("type") == "ViHost"]
    targets = [s for s in vi if s.get("viHostType") in ("VC", "vCenter")] or vi  # vCenter only, if present
    inventory = {}
    if targets:
        print("Reading vSphere inventory (component hosts):")
    for s in targets:
        name = s["name"]
        q = urllib.parse.quote(name, safe="")
        base = f"/api/v1/inventory/vmware/hosts/{q}?hierarchyTypeFilter=HostsAndClusters"
        items, vms_by_host, errors = [], {}, []
        try:
            hosts = client.get_all(f"{base}&typeFilter=Host")
            items += hosts
            for h in hosts:
                hn = _obj(h).get("name")
                if not hn:
                    continue
                vms = client.get_all(f"{base}&typeFilter=VirtualMachine"
                                     f"&parentContainerNameFilter={urllib.parse.quote(hn, safe='')}")
                names = [_obj(v).get("name") for v in vms if _obj(v).get("name")]
                if names:
                    vms_by_host[hn] = names
            if vms_by_host:
                inventory[name] = {"method": "legacy", "vmsByHost": vms_by_host,
                                   "hostsByCluster": legacy_clusters(client, base)}
                print(f"  [OK]   Inventory {name:<16} {sum(map(len, vms_by_host.values()))} VMs / {len(vms_by_host)} hosts")
                continue
            items += client.get_all(f"{base}&typeFilter=VirtualMachine")
        except Exception as e:  # noqa: BLE001
            errors.append(f"legacy: {e}")
        try:
            items += client.post_all(f"/api/v1/inventory/{q}", {"hierarchyType": "HostsAndClusters"})
        except Exception as e:  # noqa: BLE001
            errors.append(f"browser: {e}")
        if not items:
            raw["_errors"][f"inventory {name}"] = "; ".join(errors)
            print(f"  [skip] Inventory {name:<16} {'; '.join(errors)}")
            continue
        inventory[name] = {"method": "items", "items": items}
        kinds = {}
        for i in items:
            t = _lc(_obj(i).get("type"))
            kinds[t] = kinds.get(t, 0) + 1
        print(f"  [OK]   Inventory {name:<16} {len(items)} objects ("
              + ", ".join(f"{k or '?'}={v}" for k, v in sorted(kinds.items())) + ")")
    return inventory


def legacy_clusters(client, base):
    """Legacy inventory browser: cluster name -> its ESXi host names (one query per cluster)."""
    out = {}
    try:
        for c in client.get_all(f"{base}&typeFilter=Cluster"):
            cn = _obj(c).get("name")
            if cn:
                hosts = client.get_all(f"{base}&typeFilter=Host&parentContainerNameFilter={urllib.parse.quote(cn, safe='')}")
                out[cn] = [_obj(h).get("name") for h in hosts if _obj(h).get("name")]
    except Exception:  # noqa: BLE001
        pass   # the clusters only group the report's hosts
    return out


def host_clusters(raw):
    """
    ESXi host name (lowercase) -> {"name": cluster, "vcenter": vCenter}, from the Veeam inventory:
    host objects carry the cluster in their URN ("vc:...;cluster:domain-c15;esx:host-26") or as parent.
    """
    out = {}
    for vc, inv in (raw.get("inventory") or {}).items():
        for cn, hosts in (inv.get("hostsByCluster") or {}).items():
            for h in hosts:
                out[_lc(h)] = {"name": cn, "vcenter": vc}
        objs = [_obj(i) for i in inv.get("items") or []]
        clusters = {o.get("objectId"): o.get("name") for o in objs if _lc(o.get("type")) == "cluster" and o.get("objectId")}
        for o in objs:
            if _lc(o.get("type")) not in ("host", "esxi", "esxihost") or not o.get("name"):
                continue
            m = re.search(r"(?:^|;)cluster:([^;]+)", o.get("urn") or "")
            cn = clusters.get(m.group(1)) if m else clusters.get(o.get("parentId"))
            if cn:
                out[_lc(o["name"])] = {"name": cn, "vcenter": vc}
    return out


def probe_port(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def query_em(host, user, password, ctx, timeout=20):
    """
    Log in to the Enterprise Manager REST API (port 9398) and list the backup
    servers registered to it. Returns a dict for the node details.
    """
    base = f"https://{host}:{EM_REST_PORT}/api"
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    req = urllib.request.Request(f"{base}/sessionMngr/?v=latest", method="POST", data=b"")
    req.add_header("Authorization", f"Basic {auth}")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        sid = r.headers.get("X-RestSvcSessionId")
    req = urllib.request.Request(f"{base}/backupServers?format=Entity")
    req.add_header("X-RestSvcSessionId", sid or "")
    req.add_header("Accept", "application/json")
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        res = json.loads(r.read() or b"{}")
    servers = res.get("BackupServers") or res.get("Refs") or res.get("BackupServer") or []
    if isinstance(servers, dict):
        servers = servers.get("BackupServer") or servers.get("Ref") or []
    names = [s.get("Name") or s.get("DnsName") or s.get("name") for s in servers]
    return {"registered": [n for n in names if n]}


def collect_enterprise_managers(args, vbr_host, password, raw):
    """
    The VBR REST API does not expose which Enterprise Manager the server is
    registered to, so EMs come from --em, plus an automatic check for an EM
    installed on the VBR host itself (EM REST port 9398 open).
    """
    hosts = list(args.em or [])
    if vbr_host and probe_port(vbr_host, EM_REST_PORT):
        hosts.append(vbr_host)
    ems, seen = [], set()
    ctx = make_ssl_context(args.insecure, args.ca_bundle)
    for h in hosts:
        if h.lower() in seen:
            continue
        seen.add(h.lower())
        em = {"host": h, "source": "Manual (--em)" if h in (args.em or []) else "EM REST detected on VBR host (9398)"}
        if args.user and password:
            try:
                em.update(query_em(h, args.em_user or args.user, args.em_password or password, ctx))
                em["connected"] = True
            except Exception as e:  # noqa: BLE001 - the EM node is still drawn without verification
                em["error"] = str(e)
        ems.append(em)
        print(f"  [OK]   Enterprise Manager     {h}" + (f" (verification failed: {em['error']})" if em.get("error") else ""))
        if "401" in em.get("error", ""):
            print("         EM rejected the login. Check --em-user / --em-password, the account format\n"
                  "         (DOMAIN\\user, or EMHOST\\user for a local account) and that the account has\n"
                  "         an Enterprise Manager role (Settings > Roles). The EM is still drawn.")
    raw["enterpriseManagers"] = ems


# --------------------------------------------------------------------------
# vCenter REST API (optional): VM -> ESXi host placement, with guest hostname / IP
# --------------------------------------------------------------------------

class VCenterClient:
    """
    Minimal read-only vSphere Automation REST client.
    Uses /api (vCenter 7.0 U2+) and falls back to the older /rest endpoints.
    """

    def __init__(self, host, ctx, timeout=30):
        self.base = f"https://{host}"
        self.ctx = ctx
        self.timeout = timeout
        self.sid = None
        self.api = None   # "api" or "rest"

    def _request(self, method, path, headers=None):
        req = urllib.request.Request(self.base + path, method=method, data=b"" if method == "POST" else None)
        req.add_header("Accept", "application/json")
        if self.sid:
            req.add_header("vmware-api-session-id", self.sid)
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
            body = r.read()
            return json.loads(body) if body else None

    def login(self, user, password):
        auth = {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}
        try:
            self.sid = self._request("POST", "/api/session", auth)
            self.api = "api"
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            self.sid = (self._request("POST", "/rest/com/vmware/cis/session", auth) or {}).get("value")
            self.api = "rest"

    def logout(self):
        try:
            self._request("DELETE", "/api/session" if self.api == "api" else "/rest/com/vmware/cis/session")
        except Exception:
            pass

    def _get(self, api_path, rest_path):
        if self.api == "api":
            return self._request("GET", api_path)
        return (self._request("GET", rest_path) or {}).get("value")

    def hosts(self):
        return self._get("/api/vcenter/host", "/rest/vcenter/host") or []

    def vms_on_host(self, host_id):
        q = urllib.parse.quote(host_id, safe="")
        return self._get(f"/api/vcenter/vm?hosts={q}", f"/rest/vcenter/vm?filter.hosts={q}") or []

    def guest(self, vm_id):
        """Guest hostname and IP addresses; needs a powered-on VM with VMware Tools."""
        q = urllib.parse.quote(vm_id, safe="")
        out = {"guestHost": None, "ips": []}
        try:
            ident = self._get(f"/api/vcenter/vm/{q}/guest/identity", f"/rest/vcenter/vm/{q}/guest/identity") or {}
            out["guestHost"] = ident.get("host_name")
            if ident.get("ip_address"):
                out["ips"].append(ident["ip_address"])
        except Exception:
            return out
        if self.api == "api":
            try:
                for nic in self._request("GET", f"/api/vcenter/vm/{q}/guest/networking/interfaces") or []:
                    for a in ((nic.get("ip") or {}).get("ip_addresses") or []):
                        if a.get("ip_address") and a["ip_address"] not in out["ips"]:
                            out["ips"].append(a["ip_address"])
            except Exception:
                pass
        return out


def login_vcenter(vc, vc_host, user, password):
    """
    Log in to one vCenter. If it rejects the login (HTTP 401), ask once more for that
    vCenter's user and password, since vCenters often use different accounts.
    Only asks when running in a terminal.
    """
    try:
        vc.login(user, password)
    except urllib.error.HTTPError as e:
        if e.code != 401 or not sys.stdin.isatty():
            raise
        print(f"  Login to {vc_host} failed: incorrect user name or password.")
        user = input(f"  vCenter user for {vc_host} [{user}]: ").strip() or user
        vc.login(user, getpass.getpass(f"  Password for {user} on {vc_host}: "))


def collect_vcenter(args, raw, password):
    """
    Read hosts, VMs and guest identity from each vCenter registered in VBR
    (or the ones given with --vcenter). Stored in raw["vcenter"] for --from-raw.
    """
    targets = list(args.vcenter or [])
    if not targets:
        targets = [s["name"] for s in raw.get("managedServers") or []
                   if s.get("type") == "ViHost" and s.get("viHostType") in ("VC", "vCenter")]
    if not targets:
        print("  [skip] vCenter REST            no vCenter registered in VBR (use --vcenter)")
        return
    ctx = make_ssl_context(args.insecure, args.ca_bundle)
    raw["vcenter"] = {}
    for vc_host in targets:
        vc = VCenterClient(vc_host, ctx)
        try:
            login_vcenter(vc, vc_host, args.vcenter_user, password)
        except Exception as e:  # noqa: BLE001
            raw["_errors"][f"vCenter {vc_host}"] = f"login failed: {e}"
            print(f"  [skip] vCenter {vc_host:<18} login failed: {e}")
            if "401" in str(e):
                print("         Check --vcenter-user / --vcenter-password (e.g. readonly@vsphere.local).")
            continue
        try:
            hosts, vms = [], []
            for h in vc.hosts():
                hosts.append({"name": h.get("name"), "id": h.get("host"),
                              "connection": h.get("connection_state"), "power": h.get("power_state")})
                for v in vc.vms_on_host(h.get("host")):
                    vms.append({"name": v.get("name"), "id": v.get("vm"), "host": h.get("name"),
                                "power": v.get("power_state")})
            on = [v for v in vms if v.get("power") == "POWERED_ON"]
            with ThreadPoolExecutor(max_workers=8) as pool:
                for v, g in zip(on, pool.map(lambda x: vc.guest(x["id"]), on)):
                    v.update(g)
            raw["vcenter"][vc_host] = {"api": vc.api, "hosts": hosts, "vms": vms}
            try:
                # {"product": "VMware vCenter Server", "version": "8.0.3.00400", "build": "24322831", ...}
                raw["vcenter"][vc_host]["version"] = vc._get("/api/appliance/system/version",
                                                             "/rest/appliance/system/version")
            except Exception as e:  # noqa: BLE001
                raw["_errors"][f"vCenter {vc_host} version"] = str(e)
            with_guest = sum(1 for v in vms if v.get("guestHost") or v.get("ips"))
            print(f"  [OK]   vCenter {vc_host:<18} {len(hosts)} hosts, {len(vms)} VMs ({with_guest} with guest info)")
        except Exception as e:  # noqa: BLE001
            raw["_errors"][f"vCenter {vc_host}"] = str(e)
            print(f"  [skip] vCenter {vc_host:<18} {e}")
        finally:
            vc.logout()


# --------------------------------------------------------------------------
# Normalization: raw API data -> node / link model
# --------------------------------------------------------------------------

OBJECT_REPO_TYPES = {"amazons3", "s3compatible", "azureblob", "azurearchive", "googlecloud",
                     "ibmcloud", "wasabicloud", "amazons3glacier", "veeamdatacloudvault",
                     "amazonsnowballedge", "s3", "smartobjects3",   # smartobjects3: Object First
                     # REST 1.3-rev2 (ERepositoryType); s3integrated: Object First on VBR v13
                     "s3integrated", "s3glaciercompatible", "veeamvault", "veeamdatacloudvaultarchive",
                     "veeamdatacloudvaultawsexternal", "veeamdatacloudvaultazureexternal", "elevenelevens3",
                     "amazons3external", "amazons3glacierexternal", "azurestorageexternal",
                     "azurearchivestorageexternal", "googlecloudstorageexternal", "googlearchivestorageexternal"}
SHARE_REPO_TYPES = {"smb", "nfs"}
DEDUP_REPO_TYPES = {"ddboost", "exagrid", "hpstoreonce", "quantum", "infinidat", "fujitsu",
                    "delldatadomain", "hpestoreonce"}   # REST 1.3-rev2 names (lab)


LOCAL_HOSTS = {"localhost", ".", "127.0.0.1", "::1"}

# REST job types -> the wording of the VBR console's Jobs view (the PowerShell collector uses the same names)
JOB_TYPES = {"vspherebackup": "VMware Backup", "hypervbackup": "Hyper-V Backup",
             "vspherereplica": "VMware Replication", "hypervreplica": "Hyper-V Replication",
             "clouddirectorbackup": "Cloud Director Backup", "filebackup": "File Backup",
             "objectstoragebackup": "Object Storage Backup", "filebackupcopy": "Backup Copy",
             "entraidtenantbackup": "Entra ID Tenant Backup", "entraidauditlogbackup": "Entra ID Log Backup",
             "surebackupcontentscan": "SureBackup", "surebackup": "SureBackup", "backupcopy": "Backup Copy",
             "proxmoxbackupjob": "Proxmox VE Backup", "nutanixahvbackupjob": "Nutanix AHV Backup"}
# What the console's type leaves out, shown under it
JOB_TYPE_DETAILS = {"filebackupcopy": "File share", "surebackupcontentscan": "Content scan"}
# Plug-in platform servers in REST 1.3-rev2+ (HPE Morpheus VME is not in the REST API)
PLUGIN_SERVER_TYPES = {"ProxmoxNode": "Proxmox VE", "ProxmoxCluster": "Proxmox VE",
                       "NutanixCluster": "Nutanix AHV", "PrismCentral": "Nutanix AHV"}
PLUGIN_JOB_TYPES = {"proxmoxbackupjob": "Proxmox VE", "nutanixahvbackupjob": "Nutanix AHV"}
# Plug-in platform IDs (backups' platformId; the PowerShell collector uses the same IDs)
PLUGIN_PLATFORM_IDS = {"799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2": "Nutanix AHV",
                       "01208ee8-47fe-4ea8-8727-5115874da1ad": "Proxmox VE",
                       "2d470d24-b6bb-4fa3-b7ff-f0fc1137ca52": "HPE Morpheus VME"}
PLUGIN_JOB_LABELS = {"Nutanix AHV": "Nutanix AHV Backup", "Proxmox VE": "Proxmox VE Backup",
                     "HPE Morpheus VME": "HPE Morpheus VME Backup"}
# Backup platforms (platformName) -> the wording of the VBR console's Backups view
BACKUP_PLATFORMS = {"vmware": "VMware", "hyperv": "Hyper-V", "nutanix": "Nutanix AHV", "proxmox": "Proxmox VE",
                    "clouddirector": "VMware Cloud Director", "vcd": "VMware Cloud Director",
                    "windowsphysical": "Windows", "endpoint": "Windows", "linuxphysical": "Linux",
                    "unixphysical": "Unix", "solarisphysical": "Unix", "macphysical": "Mac",
                    "unstructureddata": "Unstructured data", "nas": "Unstructured data", "entraid": "Microsoft Entra ID"}


def backup_platform(platform, platform_id, job_type):
    if platform_id in PLUGIN_PLATFORM_IDS:
        return PLUGIN_PLATFORM_IDS[platform_id]
    p = _lc(platform)
    if p in BACKUP_PLATFORMS:
        return BACKUP_PLATFORMS[p]
    if p == "customplatform":
        return "Image-level" if "copy" in _lc(job_type) else "Plug-in"
    return platform or None
AGENT_OS = {"windows": "Windows", "linux": "Linux", "mac": "Mac", "unix": "Unix", "solaris": "Unix", "aix": "Unix"}


def job_type_label(j):
    t = j.get("type") or ""
    if _lc(t) in JOB_TYPES:
        return JOB_TYPES[_lc(t)]
    # WindowsAgentBackup (managed by the backup server): "Windows Agent Backup"; WindowsAgentBackupServerPolicy
    # (managed by the agent): "Windows Agent Policy", as the console names them
    m = re.match(r"^(windows|linux|mac|unix|solaris|aix)agentbackup(.*)$", _lc(t))
    if m:
        return f"{AGENT_OS[m.group(1)]} Agent {'Policy' if 'policy' in m.group(2) else 'Backup'}"
    return t


def job_type_detail(j):
    t = _lc(j.get("type"))
    if t == "backupcopy":
        return j.get("mode")   # Immediate / Periodic
    return JOB_TYPE_DETAILS.get(t)


RETENTION_UNITS = {"days": "day", "restorepoints": "restore point", "weeks": "week", "months": "month", "years": "year"}


def retention_text(quantity, unit):
    """'7 days', '1 restore point': the collectors' shared English form (translated in the template)."""
    if not isinstance(quantity, int) or not unit:
        return None
    return f"{quantity} {unit}" + ("" if quantity == 1 else "s")


def job_retention(j):
    """Short-term retention of a job: storage / target / backupRepository.retentionPolicy, or a replica's restore points."""
    rp = next((x for x in find_all(j, "retentionPolicy") if isinstance(x, dict)), None)
    if rp:
        return retention_text(rp.get("quantity"), RETENTION_UNITS.get(_lc(rp.get("type"))))
    return retention_text((j.get("jobSettings") or {}).get("restorePointsToKeep"), "restore point")


def job_encrypted(j):
    """Whether a job encrypts its backups (None when the job has no encryption setting)."""
    return next((x.get("isEnabled") for x in find_all(j, "encryption")
                 if isinstance(x, dict) and isinstance(x.get("isEnabled"), bool)), None)


def unstructured_name(u):
    """Display name of an unstructured data server: share name / path, or the object storage account."""
    return (u.get("name") or u.get("path") or u.get("friendlyName") or find_first(u.get("account") or {}, "friendlyName")
            or find_first(u.get("account") or {}, "serviceEndpoint") or u.get("type"))


def canonical_host(name):
    """
    The DNS name of a host given as an IP or a short name / alias (forward, then reverse lookup),
    or None when DNS has nothing better. Full names are kept as given.
    """
    if not name or _lc(name) in LOCAL_HOSTS or (not _is_ip(name) and "." in name):
        return None
    try:
        addr = name if _is_ip(name) else socket.gethostbyname(name)
        ptr = socket.gethostbyaddr(addr)[0]
    except OSError:
        return None
    if ptr and _lc(ptr) != _lc(name) and not _is_ip(ptr) and (_is_ip(name) or "." in ptr):
        return ptr
    return None


def _lc(s):
    return (s or "").strip().lower()


def _is_ip(s):
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


def find_all(obj, key):
    """Recursively collect every value stored under the given key."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                out.append(v)
            out.extend(find_all(v, key))
    elif isinstance(obj, list):
        for v in obj:
            out.extend(find_all(v, key))
    return out


def find_first(obj, key):
    v = find_all(obj, key)
    return v[0] if v else None


def placement_index(raw, csv_rows):
    """
    Build two lookups: lowercase VM name / IP -> placement info, and short name (first label) -> placement info.
    Priority: manual CSV, then vCenter REST (guest hostname / IP), then the VBR inventory.
    """
    index, short = {}, {}

    def add(key, info, into=index):
        k = _lc(key)
        if k and k not in into:
            into[k] = info

    def add_names(name, info):
        if not name:
            return
        add(name, info)
        if not _is_ip(name):
            add(name.split(".")[0], info, short)

    for r in csv_rows:
        if r.get("Component") and r.get("Host"):
            add_names(r["Component"], {"host": r["Host"], "vm": r.get("VM"), "source": "Manual CSV", "platform": "vi"})

    for vc, data in (raw.get("vcenter") or {}).items():
        src = f"vCenter REST ({vc})"
        for vm in data.get("vms") or []:
            if not vm.get("host"):
                continue
            info = {"host": vm["host"], "vm": vm.get("name"), "source": src, "platform": "vi", "ips": vm.get("ips")}
            add_names(vm.get("name"), info)
            add_names(vm.get("guestHost"), info)
            for ip in vm.get("ips") or []:
                add(ip, info)

    for vc, inv in (raw.get("inventory") or {}).items():
        src = f"Veeam inventory ({vc})"
        if inv.get("method") == "legacy":
            for host, vms in (inv.get("vmsByHost") or {}).items():
                for vm in vms:
                    add_names(vm, {"host": host, "vm": vm, "source": src, "platform": "vi"})
            continue
        # Raw inventory objects: resolve each VM's host via parent references, then any
        # string field (path, parent name, ...) that names a known ESXi host
        objs = [_obj(i) for i in inv.get("items") or []]
        by_id = {}
        for o in objs:
            for k in ("objectId", "id", "urn"):
                if o.get(k):
                    by_id[o[k]] = o
        host_names = {_lc(o.get("name")): o.get("name") for o in objs if _lc(o.get("type")) in ("host", "esxi", "esxihost")}
        host_names.update({_lc(h["name"]): h["name"] for h in raw.get("managedServers") or []
                           if h.get("type") == "ViHost" and h.get("viHostType") == "ESXi"})
        for o in objs:
            if _lc(o.get("type")) not in ("virtualmachine", "vm"):
                continue
            host, cur, hops = None, o, 0
            while cur and hops < 10 and not host:
                parent = next((cur.get(k) for k in ("parentId", "parentObjectId", "parentUrn", "parent") if cur.get(k)), None)
                cur = by_id.get(parent) if isinstance(parent, str) else None
                if cur and _lc(cur.get("type")) in ("host", "esxi", "esxihost"):
                    host = cur.get("name")
                hops += 1
            if not host:
                for v in _strings(o, skip=("name",)):
                    for seg in re.split(r"[\\/]", v):
                        if _lc(seg) in host_names:
                            host = host_names[_lc(seg)]
            if host:
                add_names(o.get("name"), {"host": host, "vm": o.get("name"), "source": src, "platform": "vi"})
    return index, short


def _strings(obj, skip=()):
    """All string values in a nested dict/list, except the top-level keys in skip."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in skip:
                continue
            out += [v] if isinstance(v, str) else _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            out += [v] if isinstance(v, str) else _strings(v)
    return out


_dns_cache = {}


def name_variants(name):
    """The name itself, its short name, and whatever DNS resolves it to (both ways)."""
    out = [name]
    if not _is_ip(name):
        out.append(name.split(".")[0])
    if name not in _dns_cache:
        res = None
        try:
            res = socket.gethostbyaddr(name) if _is_ip(name) else socket.gethostbyname_ex(name)
        except OSError:
            pass
        _dns_cache[name] = res
    res = _dns_cache[name]
    if res:
        fqdn, aliases, addrs = res
        for n in [fqdn, *aliases]:
            out += [n, n.split(".")[0]]
        out += addrs
    return out


def pick_ips(addrs):
    """IPv4 addresses (no loopback / link-local), else global IPv6; comma-separated."""
    out = []
    for a in addrs or []:
        try:
            ip = ipaddress.ip_address(a)
        except ValueError:
            continue
        if not (ip.is_loopback or ip.is_link_local) and str(ip) not in out:
            out.append(str(ip))
    return ", ".join([a for a in out if "." in a] or out)


def add_ips(nodes):
    """IP addresses for the hover details, where placement did not already give the guest IPs: DNS."""
    for n in nodes.values():
        if n["kind"] in ("agent", "sobr", "object") or n["details"].get("IP"):
            continue
        name = n["details"].get("Host") or (n["name"] if n["kind"] != "repo" else None)
        if not name:
            continue
        if _is_ip(name):
            n["details"]["IP"] = name
            continue
        name_variants(name)  # fills the DNS cache
        res = _dns_cache.get(name)
        ips = pick_ips(res[2]) if res else ""
        if ips:
            n["details"]["IP"] = f"{ips} (DNS)"


def build_model(raw, csv_rows=()):
    nodes, links, warnings = {}, {}, []
    used_hosts = set()  # ids of managed servers already shown in a role

    def add_node(nid, kind, name, sub="", badges=None, details=None):
        if nid not in nodes:
            nodes[nid] = {"id": nid, "kind": kind, "name": name, "sub": sub,
                          "badges": badges or [], "details": details or {}}
        return nodes[nid]

    def add_link(src, dst, job=None, kind="data"):
        if src not in nodes or dst not in nodes or src == dst:
            return
        key = (src, dst)
        lk = links.setdefault(key, {"source": src, "target": dst, "kind": kind, "jobs": []})
        if kind == "data":
            lk["kind"] = "data"
        if job and job not in lk["jobs"]:
            lk["jobs"].append(job)

    info = raw.get("serverInfo") or {}
    meta = raw.get("_meta", {})
    # The backup server is named after the host we connected to (its DNS name when that was an IP or a
    # short name); serverInfo.name is VBR's internal name (e.g. "vbr-1a2b3c4d" on the appliance) and is
    # only used for a local connection
    conn_host = urllib.parse.urlparse(meta.get("base", "")).hostname or ""
    dns_name = meta.get("hostName") if "hostName" in meta else canonical_host(conn_host)  # older vbr_raw.json: resolve now
    vbr_name = (dns_name or (conn_host if conn_host and not _is_ip(conn_host) and _lc(conn_host) not in LOCAL_HOSTS else None)
                or info.get("name") or conn_host or "VBR")
    # A short name (an alias such as "vbr" from DNS or a hosts file) gives way to serverInfo.name when that
    # is a full name (vbr-03.corp.local); the appliance's internal name (vbr-1a2b3c4d) does not
    srv_name = info.get("name") or ""
    if "." not in vbr_name and not _is_ip(vbr_name) and "." in srv_name and not _is_ip(srv_name):
        vbr_name = srv_name
    add_node("vbr", "backup", vbr_name, f"Backup server · v{info.get('buildVersion', '?')}",
             details={"Build": info.get("buildVersion"), "Patches": ", ".join(info.get("patches") or []),
                      "Database": info.get("databaseVendor"), "VBR ID": info.get("vbrId"),
                      "Connected as": conn_host if conn_host and _lc(conn_host) not in LOCAL_HOSTS
                      and _lc(conn_host) != _lc(vbr_name) else None})

    # ---- Enterprise Manager (management tier, drawn next to the backup server)
    # EM may list this VBR by its display name, the address we connected to (often an IP) or serverInfo.name
    vbr_keys = set()
    for k in (vbr_name, conn_host, info.get("name")):
        if k:
            vbr_keys.add(_lc(k))
            if not _is_ip(k):
                vbr_keys.add(_lc(k).split(".")[0])
    for em in raw.get("enterpriseManagers") or []:
        reg = em.get("registered")
        # An empty list usually means the EM account cannot see any backup server (no EM role), not that
        # this VBR is not registered: leave "Registered to this EM" unknown
        is_reg = None if not reg else any(_lc(r) in vbr_keys or (not _is_ip(r) and _lc(r).split(".")[0] in vbr_keys)
                                              for r in reg)
        sub = "Enterprise Manager"
        if _lc(em["host"]) == _lc(urllib.parse.urlparse(meta.get("base", "")).hostname) or _lc(em["host"]) == _lc(vbr_name):
            sub += " · same host as VBR"
        add_node(f"mgmt:em:{_lc(em['host'])}", "em", em["host"], sub, details={
            "Source": em.get("source"), "URL": f"https://{em['host']}:9443",
            "Registered backup servers": ", ".join(reg) if reg else (EM_NONE_VISIBLE if reg == [] else None),
            "Registered to this EM": {True: "Yes", False: "No"}.get(is_reg),
            "Verification": f"Failed: {em['error']}" if em.get("error") else ("OK" if em.get("connected") else None)})

    # ---- Managed servers
    servers = {s["id"]: s for s in raw.get("managedServers") or []}
    by_name = {_lc(s.get("name")): s for s in servers.values()}
    # vCenter version by name; --vcenter may name it differently (IP, host:port), so with one
    # registered vCenter and one queried vCenter, pair them
    vc_versions = {_lc(vc.split(":")[0]): data.get("version") or {} for vc, data in (raw.get("vcenter") or {}).items()}
    vc_names = [_lc(s.get("name")) for s in servers.values()
                if s.get("type") == "ViHost" and s.get("viHostType") in ("VC", "vCenter")]
    if len(vc_names) == 1 and len(vc_versions) == 1 and vc_names[0] not in vc_versions:
        vc_versions = {vc_names[0]: next(iter(vc_versions.values()))}
    for s in servers.values():
        t = s.get("type", "")
        if _lc(s.get("name")) in (_lc(vbr_name), _lc(info.get("name"))):
            used_hosts.add(s["id"])
        if t == "ViHost":
            vt = s.get("viHostType", "")
            label = "vCenter Server" if vt in ("VC", "vCenter") else ("ESXi" if vt == "ESXi" else "VMware vSphere")
            ver = vc_versions.get(_lc(s.get("name"))) or {}
            short = ".".join(str(ver.get("version") or "").split(".")[:3])   # 8.0.3.00400 -> 8.0.3
            add_node(s["id"], "vi_host", s["name"], f"{label}{' ' + short if short else ''} · Source host",
                     details={"Type": f"{t} / {vt}", "Description": s.get("description"),
                              "Status": s.get("status"), "Product": ver.get("product"),
                              "Version": ver.get("version"), "Build": ver.get("build")})
            used_hosts.add(s["id"])
        elif t in ("HvServer", "HvCluster", "SCVMM", "HvHost"):
            label = {"HvServer": "Hyper-V host", "HvCluster": "Hyper-V cluster", "SCVMM": "SCVMM"}.get(t, t)
            add_node(s["id"], "hv_host", s["name"], f"{label} · Source host", badges=["M"],
                     details={"Type": t, "Description": s.get("description"), "Status": s.get("status"),
                              "Cluster": s.get("parentHostName"),
                              "Data Mover": "On-host proxy (Veeam Data Mover Service)"})
            used_hosts.add(s["id"])
        elif t in PLUGIN_SERVER_TYPES:
            plat = PLUGIN_SERVER_TYPES[t]
            add_node(s["id"], "ext_host", s["name"], f"{plat} · Source host",
                     details={"Type": t, "Platform": plat, "Description": s.get("description"), "Status": s.get("status")})
            used_hosts.add(s["id"])
        elif t in ("CloudDirectorHost",):
            add_node(s["id"], "vi_host", s["name"], "VMware Cloud Director",
                     details={"Type": t, "Description": s.get("description")})
            used_hosts.add(s["id"])

    def host_name(hid):
        return (servers.get(hid) or {}).get("name") if hid else None

    # ---- Proxies
    for p in raw.get("proxies") or []:
        t = p.get("type", "")
        srv = p.get("server") or {}
        hid = srv.get("hostId")
        used_hosts.add(hid)
        label = {"ViProxy": "VMware backup proxy", "HvProxy": "Hyper-V off-host proxy",
                 "GeneralPurposeProxy": "General-purpose proxy",
                 # Plug-in platform workers: in EProxyType since REST 1.3-rev2, but not returned on v13.1
                 "NutanixAHV": "Nutanix AHV worker", "PVE": "Proxmox VE worker"}.get(t, t)
        # General-purpose proxies are named after their server, as in PowerShell (REST calls them "Backup Proxy")
        name = (host_name(hid) if t == "GeneralPurposeProxy" else None) or p.get("name") or host_name(hid) or "proxy"
        add_node(p["id"], "proxy", name, label, badges=["M"],
                 details={"Type": t, "Host": host_name(hid), "Transport mode": srv.get("transportMode"),
                          "Max tasks": srv.get("maxTaskCount"), "Description": p.get("description"),
                          "_ptype": t})

    # ---- WAN accelerators
    for w in raw.get("wanAccelerators") or []:
        hid = (w.get("server") or {}).get("hostId") or w.get("hostId")
        used_hosts.add(hid)
        add_node(w["id"], "proxy", w.get("name") or host_name(hid) or "WAN", "WAN accelerator", badges=["M"],
                 details={"Host": host_name(hid), "Description": w.get("description"), "_ptype": "WAN"})

    # ---- Repositories
    states = {r.get("id"): r for r in raw.get("repositoryStates") or []}
    sobr_extents = {}
    for sb in raw.get("scaleOutRepositories") or []:
        perf = (sb.get("performanceTier") or {})
        ext = perf.get("performanceExtents") or perf.get("extents") or []
        for e in ext:
            sobr_extents[e.get("id")] = sb["id"]

    def fmt_gb(v):
        return f"{v:,.0f} GB" if isinstance(v, (int, float)) else None

    for r in raw.get("repositories") or []:
        # VBR's own temporary repository (/tmp/VeeamTempRepo<id> on the appliance): the console and
        # PowerShell do not list it
        if "veeamtemprepo" in _lc((r.get("repository") or {}).get("path")):
            continue
        t = r.get("type", "")
        st = states.get(r["id"], {})
        hid = r.get("hostId") or (r.get("repository") or {}).get("hostId")
        gateways = find_all(r.get("share") or {}, "gatewayServerIds")
        used_hosts.add(hid)
        for gl in gateways:
            used_hosts.update(gl or [])
        tl = _lc(t)
        # Object storage connection mode, named as PowerShell does (Direct / Gateway). As in the console, the
        # gateways are listed only in Gateway mode: in Direct mode the API still returns unused gatewayServerIds
        mode = find_first(r.get("account") or {}, "connectionType") if tl in OBJECT_REPO_TYPES else None
        if _lc(mode) == "selectedgateway":
            mode = "Gateway"
        if tl in OBJECT_REPO_TYPES and _lc(mode) != "direct":
            gateways += find_all(r.get("account") or {}, "gatewayServerIds")
        # Dedup appliances with selected gateways (gatewayServer.autoSelection false); with automatic selection
        # the console's Host column says "Gateway (auto)" and lists none
        if tl in DEDUP_REPO_TYPES:
            for g in find_all(r, "gatewayServer"):
                if isinstance(g, dict) and g.get("autoSelection") is False:
                    gateways.append(g.get("gatewayServerIds") or [])
                    used_hosts.update(g.get("gatewayServerIds") or [])
        gw_names = [host_name(g) for gl in gateways for g in (gl or []) if host_name(g)]
        if tl in OBJECT_REPO_TYPES:
            kind, label, badges = "object", f"Object storage · {t}", []
        elif tl in SHARE_REPO_TYPES:
            kind, label, badges = "repo", f"NAS share · {t.upper()}", ["M"] if gw_names else []
        elif tl in DEDUP_REPO_TYPES:
            kind, label, badges = "repo", f"Dedup appliance · {t}", []
        else:
            hardened = tl == "linuxhardened" or (r.get("repository") or {}).get("makeRecentBackupsImmutableDays")
            kind = "repo"
            label = {"winlocal": "Windows repository", "linuxlocal": "Linux repository",
                     "linuxhardened": "Hardened Linux repository"}.get(tl, f"Repository · {t}")
            if hardened and "Hardened" not in label:
                label += " (immutable)"
            badges = ["M"]
        cap, free = st.get("capacityGB"), st.get("freeGB")
        details = {"Type": t, "Host": host_name(hid) or st.get("hostName") or mode,
                   "Path": st.get("path") or (r.get("repository") or {}).get("path")
                   or (r.get("share") or {}).get("sharePath") or find_first(r, "bucketName"),
                   "Gateway": ", ".join(gw_names) or None,
                   "Connection mode": mode,
                   "Capacity": fmt_gb(cap), "Free": fmt_gb(free),
                   "Description": r.get("description")}
        if r["id"] in sobr_extents:
            details["SOBR extent of"] = sobr_extents[r["id"]]
        n = add_node(r["id"], kind, r.get("name"), label, badges=badges, details=details)
        if isinstance(cap, (int, float)) and cap:
            n["usage"] = round(1 - (free or 0) / cap, 3)

    # Application Backup Repositories: REST has no endpoint for them, only the role on their managed server
    for s in servers.values():
        comps = find_all(s.get("optionalComponents") or {}, "optionalComponent")
        if "ApplicationBackupRepository" in comps:
            add_node(f"abr:{s['id']}", "repo", s.get("name"), "Application Backup Repository", badges=["M"],
                     details={"Type": "ApplicationBackupRepository", "Host": s.get("name")})
            used_hosts.add(s["id"])

    for sb in raw.get("scaleOutRepositories") or []:
        perf = sb.get("performanceTier") or {}
        ext = perf.get("performanceExtents") or perf.get("extents") or []
        ext_names = [(nodes.get(e.get("id")) or {}).get("name") or e.get("name") for e in ext]
        cap_tier = sb.get("capacityTier") or {}
        arch_tier = sb.get("archiveTier") or {}

        def tier(t):
            ids = [e.get("id") for e in t.get("extents") or [] if isinstance(e, dict)] + find_all(t, "extentId")
            on = t.get("isEnabled") or t.get("enabled")
            ids = [i for i in ids if i in nodes] if on else []
            return ids, ", ".join(nodes[i]["name"] for i in ids) or ("Enabled" if on else "—")

        cap_ids, cap_label = tier(cap_tier)
        arch_ids, arch_label = tier(arch_tier)
        add_node(sb["id"], "sobr", sb.get("name"), f"Scale-out repository · {len(ext)} extents",
                 details={"Performance tier": ", ".join(filter(None, ext_names)),
                          "Capacity tier": cap_label, "Archive tier": arch_label,
                          "Description": sb.get("description")})
        nodes[sb["id"]]["extents"] = [e.get("id") for e in ext]
        if cap_ids:
            nodes[sb["id"]]["capacity"] = cap_ids
        if arch_ids:
            nodes[sb["id"]]["archive"] = arch_ids
        for c in cap_ids:
            add_link(sb["id"], c, "Capacity tier offload", "copy")
        for e in ext:
            if e.get("id") in nodes:
                nodes[e["id"]]["details"]["SOBR extent of"] = sb.get("name")
                nodes[e["id"]]["inSobr"] = sb["id"]

    # ---- Agents (protection groups)
    for pg in raw.get("protectionGroups") or []:
        add_node(pg["id"], "agent", pg.get("name"), f"Veeam Agent · {pg.get('type', 'Protection group')}",
                 badges=["A"], details={"Type": pg.get("type"), "Description": pg.get("description"),
                                        "Computers": pg.get("computersCount") or pg.get("objectsCount")})

    # ---- Jobs -> data flow
    proxies_by_type = {}
    for n in nodes.values():
        if n["kind"] == "proxy":
            proxies_by_type.setdefault(n["details"].get("_ptype"), []).append(n["id"])

    def source_node(host, platform):
        s = by_name.get(_lc(host))
        if s and s["id"] in nodes:
            return s["id"]
        nid = f"src:{platform}:{_lc(host)}"
        kind = "hv_host" if platform == "hv" else "vi_host"
        add_node(nid, kind, host, "Source host (not in managed servers)", badges=["M"] if kind == "hv_host" else [])
        return nid

    jobs = raw.get("jobs") or []
    job_rows = []
    server_names = {s["id"]: s.get("name") for s in servers.values()}
    server_names.update({u["id"]: unstructured_name(u) for u in raw.get("unstructuredDataServers") or [] if u.get("id")})

    def job_repo(j):
        # Replicas keep only their metadata in a repository (jobSettings.metadataRepositoryId)
        return ((j.get("storage") or {}).get("backupRepositoryId") or next(iter(find_all(j, "backupRepositoryId")), None)
                or next(iter(find_all(j, "metadataRepositoryId")), None))

    # Plug-in jobs come without details (only id, name, type, isDisabled): their repository is in /backups
    backup_repo = {b.get("jobId"): b.get("repositoryId") for b in raw.get("backups") or [] if b.get("jobId")}
    repo_of_job = {j.get("id"): job_repo(j) or backup_repo.get(j.get("id")) for j in jobs}
    job_names = {j.get("id"): j.get("name") for j in jobs}
    job_ids_by_name = {j.get("name"): j.get("id") for j in jobs if j.get("name")}
    per_backup = backup_stats(raw)
    # Last run and result: /jobs/states, else the job's last session (plug-in jobs, configuration backup)
    job_state = {x.get("id"): {"lastRun": _ts(x.get("lastRun")), "lastResult": x.get("lastResult"), "status": x.get("status")}
                 for x in raw.get("jobStates") or [] if x.get("id")}
    job_state.update({jid: v for jid, v in (raw.get("lastSessions") or {}).items() if jid not in job_state})

    def last_run(jid, job_type=""):
        # As in the console: no result without a run time, and N/A for policies the agent manages itself
        st = job_state.get(jid) or {}
        res = st.get("lastResult")
        if job_type.endswith("Agent Policy"):
            return {"lastRun": st.get("lastRun"), "lastResult": "N/A"}
        if st.get("status") == "Running":   # lastResult is None while the job runs
            return {"lastRun": st.get("lastRun"), "lastResult": "Running"}
        keep = st.get("lastRun") and res not in (None, "None")
        return {"lastRun": st.get("lastRun"), "lastResult": res if keep else None}
    replica_targets = []   # (proxies or source hosts, destination host, its vCenter, label): linked once ESXi hosts are known
    tenant_names = {e.get("id"): e.get("name") or e.get("azureTenantId") for e in raw.get("entraIdTenants") or [] if e.get("id")}
    for j in jobs:
        jt = j.get("type", "")
        jtl = _lc(jt)
        name = j.get("name")
        storage = j.get("storage") or {}
        repo = repo_of_job.get(j.get("id"))
        # Backup jobs: storage.backupProxies {autoSelection, proxyIds}; replicas: dataTransfer.sourceProxies
        proxy_cfg = (storage.get("backupProxies") or next(iter(find_all(j, "backupProxies")), {})
                     or (j.get("dataTransfer") or {}).get("sourceProxies") or {})
        sel_proxies = [p for p in (proxy_cfg.get("proxyIds") or []) if p in nodes]
        auto = proxy_cfg.get("autoSelection", proxy_cfg.get("autoSelectEnabled", not sel_proxies))
        includes = (j.get("virtualMachines") or {}).get("includes") or []
        hosts = set()
        for inc in includes:
            obj = _obj(inc)
            if obj.get("hostName"):
                hosts.add(obj["hostName"])
        is_agent = "agent" in jtl or "computer" in jtl
        is_copy = "copy" in jtl
        # Protection groups of an agent job; source jobs of a backup copy / SureBackup job
        pg_ids = list(dict.fromkeys(i for c in j.get("computers") or [] for i in (c.get("protectionGroupId"), c.get("id"))
                                    if isinstance(i, str) and nodes.get(i, {}).get("kind") == "agent")) if is_agent else []
        src_jobs = [_obj(x) for x in ((j.get("sourceObjects") or {}).get("includes") or {}).get("jobs") or []]
        src_jobs += [_obj(x) for x in (j.get("linkedJobs") or {}).get("includes") or []]
        # File backup copy: its source job
        if j.get("primaryJobId"):
            src_jobs.append({"id": j["primaryJobId"], "name": job_names.get(j["primaryJobId"])})
        # Backup copy from a repository (for example an Application Backup Repository)
        src_repo_objs = [_obj(x) for x in ((j.get("sourceObjects") or {}).get("includes") or {}).get("repositories") or []]
        if is_agent:
            sources = [nodes[p]["name"] for p in pg_ids]
        elif src_jobs or src_repo_objs:
            sources = [x.get("name") or (nodes.get(x.get("id")) or {}).get("name") for x in src_jobs + src_repo_objs]
            sources = [x for x in sources if x]
        else:
            sources = sorted(hosts)
        # Entra ID tenant and audit log backups: the tenant (tenant.tenantId or storage.tenantId)
        tenant = (tenant_names.get((j.get("tenant") or {}).get("tenantId") or storage.get("tenantId"))
                  if "entraid" in jtl else None)
        if tenant:
            sources = [tenant]
        if is_agent or is_copy or "entraid" in jtl or "surebackup" in jtl:
            proxies = "—"   # no backup proxy of their own, as PowerShell shows them
        elif auto and not sel_proxies:
            proxies = "Automatic"
        else:
            proxies = ", ".join(nodes[p]["name"] for p in sel_proxies)
        objects = job_objects(j, server_names)
        objects += [{"name": x.get("name"), "type": "Job", "location": "", "size": "", "excluded": False}
                    for x in (j.get("linkedJobs") or {}).get("includes") or [] if x.get("name")]
        if tenant:
            objects.append({"name": tenant, "type": "Entra ID tenant", "location": "", "size": "", "excluded": False})
        if j.get("primaryJobId") and job_names.get(j["primaryJobId"]):
            objects.append({"name": job_names[j["primaryJobId"]], "type": "Job", "location": "", "size": "", "excluded": False})
        job_rows.append({"name": name, "type": job_type_label(j), "typeDetail": job_type_detail(j), "disabled": j.get("isDisabled"),
                         "repository": (nodes.get(repo) or {}).get("name"),
                         "sources": sources, "proxies": proxies, "objects": objects,
                         "retention": job_retention(j), "encrypted": job_encrypted(j),
                         **last_run(j.get("id"), job_type_label(j))})
        label = name + (" (disabled)" if j.get("isDisabled") else "")
        if jtl in PLUGIN_JOB_TYPES:
            # No sources in REST: every host of that platform gets an inferred link to the repository
            for h in [n["id"] for n in nodes.values() if n["kind"] == "ext_host" and n["details"].get("Platform") == PLUGIN_JOB_TYPES[jtl]]:
                if repo in nodes:
                    add_link(h, repo, label, "inferred")
            continue
        if "replica" in jtl:
            # Source host -> proxies -> target host, as PowerShell draws it (the metadata repository is not drawn).
            # Hyper-V: off-host proxies when the job selects them, else the hosts' on-host proxies (host to host)
            hv = "hyperv" in jtl
            px = sel_proxies or ([] if hv else proxies_by_type.get("ViProxy", []))
            srcs = [source_node(h, "hv" if hv else "vi") for h in hosts]
            for src in srcs:
                for p in px:
                    add_link(src, p, label, "data" if hv else "auto")
            dest = _obj((j.get("destination") or {}).get("host") or {})
            if dest.get("name"):
                replica_targets.append((px or srcs, dest["name"], dest.get("hostName"), label))
                # The Jobs table shows the target host, as the console does (the repository holds the replica metadata)
                job_rows[-1]["target"] = dest["name"]
            continue
        if repo not in nodes:
            continue
        if "vsphere" in jtl or "vmware" in jtl or "vcd" in jtl or "clouddirector" in jtl:
            px = sel_proxies or proxies_by_type.get("ViProxy", [])
            for h in hosts:
                src = source_node(h, "vi")
                if px:
                    for p in px:
                        add_link(src, p, label, "data" if sel_proxies else "auto")
                else:
                    add_link(src, repo, label)
            for p in px:
                add_link(p, repo, label, "data" if sel_proxies else "auto")
        elif "hyperv" in jtl:
            for h in hosts:
                src = source_node(h, "hv")
                if sel_proxies:  # off-host
                    for p in sel_proxies:
                        add_link(src, p, label)
                        add_link(p, repo, label)
                else:            # on-host proxy
                    add_link(src, repo, label)
        elif is_agent:
            if not pg_ids:
                pg_ids = [add_node("agents", "agent", "Veeam Agents", "Physical / virtual servers",
                                   badges=["A"])["id"]]
            for pg in pg_ids:
                add_link(pg, repo, label)
        elif not is_copy and ("file" in jtl or "nas" in jtl or "objectstorage" in jtl or "unstructured" in jtl):
            px = sel_proxies or proxies_by_type.get("GeneralPurposeProxy", [])
            for p in px:
                add_link(p, repo, label, "data" if sel_proxies else "auto")
        elif is_copy:
            # Source repositories: those of the source jobs (sourceObjects.includes.jobs), the source
            # repositories listed in the job, and the older sourceRepositoryId / source fields
            src = (j.get("sourceObjects") or {}).get("includes") or {}
            src_repos = [repo_of_job.get(x.get("id")) for x in src_jobs]
            # A copy from an Application Backup Repository names its virtual repository (type AbrVirtual,
            # another id). With one ABR in the report, that is the one; it also gives its name
            abr_nodes = [n for n in nodes.values() if n["details"].get("Type") == "ApplicationBackupRepository"]
            for x in src.get("repositories") or []:
                o = _obj(x)
                rid = o.get("id")
                if rid not in nodes and o.get("type") == "AbrVirtual" and len(abr_nodes) == 1:
                    rid = abr_nodes[0]["id"]
                    if o.get("name") and abr_nodes[0]["name"] == abr_nodes[0]["details"].get("Host"):
                        abr_nodes[0]["name"] = o["name"]
                src_repos.append(rid)
            src_repos.append(j.get("sourceRepositoryId") or next(iter(find_all(j.get("source") or {}, "backupRepositoryId")), None))
            for sr in src_repos:
                if sr in nodes:
                    add_link(sr, repo, label, "copy")

    # Plug-in jobs (Nutanix AHV, Proxmox VE, HPE Morpheus VME) that /jobs does not return: list them from
    # their backups (by job type or platform ID). Their state and sources are not in /backups.
    job_ids = {j.get("id") for j in jobs}
    plugin_jobs = {}
    for b in raw.get("backups") or []:
        jid = b.get("jobId")
        plat = PLUGIN_JOB_TYPES.get(_lc(b.get("jobType"))) or PLUGIN_PLATFORM_IDS.get(b.get("platformId"))
        if jid and jid not in job_ids and plat:
            pj = plugin_jobs.setdefault(jid, {"name": b.get("name"), "type": PLUGIN_JOB_LABELS[plat], "platform": plat, "repo": None})
            if not pj["repo"] and b.get("repositoryId") in nodes:
                pj["repo"] = b["repositoryId"]
    # Their objects: the backed-up objects named in the files of their backups. The backups also keep VMs
    # the job no longer protects, so only VMs backed up within a day of the job's newest backup are kept
    # (one run backs up its VMs minutes apart)
    obj_names = {o.get("id"): o for o in raw.get("backupObjects") or [] if o.get("id")}
    point_times = raw.get("restorePointTimes") or {}
    backup_ids_of = {}
    for b in raw.get("backups") or []:
        backup_ids_of.setdefault(b.get("jobId"), []).append(b.get("id"))
    for jid, pj in plugin_jobs.items():
        newest = {}  # VM name -> its newest backup time (None when no file gives a time)
        for bid in backup_ids_of.get(jid, []):
            for f in (raw.get("backupFiles") or {}).get(bid) or []:
                times = [_parse_time(point_times.get(p)) for p in f.get("restorePointIds") or []]
                times = [t for t in times if t] or [_parse_time(f.get("creationTime"))]
                t = max([t for t in times if t], default=None)
                for oid in f.get("objectIds") or []:
                    o = obj_names.get(oid) or {}
                    if o.get("name"):
                        if o["name"] not in newest:
                            pj.setdefault("types", {})[o["name"]] = o.get("type")
                            newest[o["name"]] = t
                        elif t and (newest[o["name"]] is None or t > newest[o["name"]]):
                            newest[o["name"]] = t
        last = max([t for t in newest.values() if t], default=None)
        objs = [{"name": n, "type": "Virtual Machine" if pj["types"][n] == "VM" else pj["types"][n] or "",
                 "location": "", "size": "", "excluded": False}
                for n, t in newest.items() if not last or not t or last - t <= dt.timedelta(days=1)]
        job_rows.append({"name": pj["name"], "type": pj["type"], "disabled": None,
                         "repository": (nodes.get(pj["repo"]) or {}).get("name"),
                         "sources": [], "proxies": "—", "objects": sorted(objs, key=lambda x: x["name"]),
                         # Cells the REST API cannot fill: "n/a" with a footnote (texts: note_<code> in template.html I18N)
                         "unavailable": {"disabled": "pluginSettings", "sources": "pluginSettings", "retention": "pluginSettings",
                                         "encrypted": "pluginSettings"},
                         **last_run(jid)})
        for h in [n["id"] for n in nodes.values() if n["kind"] == "ext_host" and n["details"].get("Platform") == pj["platform"]]:
            if pj["repo"] in nodes:
                add_link(h, pj["repo"], pj["name"], "inferred")

    # Configuration backup: listed, and its target shown on the backup server (the diagram has no links
    # from the backup server). The REST API does not return the job name; VBR names it "Backup Configuration Job"
    cb = raw.get("configBackup")
    if isinstance(cb, dict) and cb:
        rid = cb.get("backupRepositoryId")
        cb_disabled = cb.get("isEnabled") is False
        if rid in nodes:
            nodes["vbr"]["details"]["Config backup target"] = nodes[rid]["name"]
        enc = (cb.get("encryption") or {}).get("isEnabled")
        if isinstance(enc, bool):
            nodes["vbr"]["details"]["Config backup encrypted"] = "Yes" if enc else "No"
        job_rows.append({"name": "Backup Configuration Job", "type": "Configuration Backup", "disabled": cb_disabled,
                         "repository": (nodes.get(rid) or {}).get("name"), "sources": [vbr_name],
                         "proxies": "—", "objects": [], "encrypted": enc if isinstance(enc, bool) else None,
                         "retention": retention_text(cb.get("restorePointsToKeep"), "restore point"),
                         **last_run("configBackup")})

    # Agent backups from /backups, only when /jobs has no agent jobs (older API versions). Otherwise
    # these are backups without a job (imported or orphaned), which PowerShell does not show either.
    has_agent_jobs = any("agent" in _lc(j.get("type")) or "computer" in _lc(j.get("type")) for j in jobs)
    linked_repos_from_agents = {l["target"] for l in links.values() if nodes[l["source"]]["kind"] == "agent"}
    for b in [] if has_agent_jobs else raw.get("backups") or []:
        plat = _lc(b.get("platformName"))
        rid = b.get("repositoryId")
        if rid in nodes and ("physical" in plat or "agent" in plat) and rid not in linked_repos_from_agents:
            a = add_node("agents", "agent", "Veeam Agents", "Physical / virtual servers", badges=["A"])
            add_link(a["id"], rid, b.get("name"))

    # Re-point links to SOBR extents at the SOBR itself
    for l in list(links.values()):
        for end in ("source", "target"):
            sb = nodes[l[end]].get("inSobr")
            if sb:
                links.pop((l["source"], l["target"]), None)
                l[end] = sb
                links[(l["source"], l["target"])] = l

    if any(n["kind"] == "ext_host" for n in nodes.values()):
        warnings.append("Proxies of plug-in platforms (Proxmox VE, Nutanix AHV, HPE Morpheus VME) cannot be read "
                        "through PowerShell or the REST API and are not shown.")

    # Sources with no job link -> inferred (dashed) links.
    # With a vCenter present, ESXi hosts are normally backed up through it, so skip them.
    has_out = {l["source"] for l in links.values()}
    vi_px = proxies_by_type.get("ViProxy", [])
    has_vc = any(n["kind"] == "vi_host" and "vCenter" in n["sub"] for n in nodes.values())
    for n in list(nodes.values()):
        if n["id"] in has_out or (has_vc and n["sub"].startswith("ESXi")):
            continue
        if n["kind"] == "vi_host" and vi_px:
            for p in vi_px:
                add_link(n["id"], p, None, "inferred")
    if not jobs and raw.get("_errors", {}).get("jobs"):
        warnings.append("Could not read jobs; data flow is shown as inferred (dashed) links.")

    # Other managed servers (not holding any role)
    for s in servers.values():
        if s["id"] not in used_hosts and s["id"] not in nodes:
            add_node(s["id"], "server", s["name"], f"Managed server · {s.get('type')}",
                     details={"Type": s.get("type"), "Description": s.get("description"),
                              "Status": s.get("status")})
    # File shares, object storage accounts and Entra ID tenants, which PowerShell lists as managed servers
    # (file servers are managed servers already)
    for u in raw.get("unstructuredDataServers") or []:
        if u.get("id") and u.get("type") != "FileServer" and u["id"] not in nodes:
            add_node(u["id"], "server", unstructured_name(u), f"Managed server · {u.get('type')}",
                     details={"Type": u.get("type"), "Path": u.get("path")})
    for e in raw.get("entraIdTenants") or []:
        if e.get("id") and e["id"] not in nodes:
            add_node(e["id"], "server", e.get("name") or e.get("azureTenantId"), "Managed server · Entra ID tenant",
                     details={"Type": "Entra ID tenant", "Tenant ID": e.get("azureTenantId"), "Region": e.get("region"),
                              "Description": e.get("description")})

    # ---- ESXi hosts known to vCenter (VBR REST only lists the vCenter itself)
    for vc, data in (raw.get("vcenter") or {}).items():
        counts = {}
        for vm in data.get("vms") or []:
            counts[vm.get("host")] = counts.get(vm.get("host"), 0) + 1
        for h in data.get("hosts") or []:
            if not h.get("name") or _lc(h["name"]) in by_name:
                continue
            add_node(f"place:vi:{_lc(h['name'])}", "vi_host", h["name"], "ESXi · discovered via vCenter",
                     details={"vCenter": vc, "Connection": h.get("connection"), "Power": h.get("power"),
                              "VMs": counts.get(h["name"], 0)})

    # ---- Which ESXi host each component runs on
    place_by, place_short = placement_index(raw, csv_rows)
    if place_by or place_short:
        apply_placement(nodes, by_name, place_by, place_short, add_node, conn_host)
    elif raw.get("inventory"):
        warnings.append("The vSphere inventory was read, but it has no VM-to-host relation; component hosts "
                        "not matched (use the PowerShell version or --placement-csv)")
    elif any(n["kind"] == "vi_host" for n in nodes.values()):
        warnings.append("vSphere inventory unavailable; component hosts not matched (use --placement-csv)")

    # ---- Replica targets: proxies -> the target host (ESXi hosts are known by now), else the vCenter it belongs to
    for froms, dest, dest_vc, label in replica_targets:
        hosts_by_name = {_lc(n["name"]): n["id"] for n in nodes.values() if n["kind"] in ("vi_host", "hv_host")}
        tgt = hosts_by_name.get(_lc(dest)) or hosts_by_name.get(_lc(dest_vc))
        for f in froms:
            add_link(f, tgt, label, "copy")

    # ---- vSphere cluster of each ESXi host (the report groups hosts by cluster)
    clusters = host_clusters(raw)
    for n in nodes.values():
        if n["kind"] != "vi_host":
            continue
        c = clusters.get(_lc(n["name"]))
        if c:
            n["cluster"] = c
            n["details"]["Cluster"] = c["name"]

    add_ips(nodes)

    for n in nodes.values():
        n["details"] = {k: v for k, v in n["details"].items() if v not in (None, "", [])}

    for key, err in (raw.get("_errors") or {}).items():
        warnings.append(f"{key}: {err}")

    # Backups, as the VBR console's Backups view lists them (snapshots and backups without a job included)
    job_name = {j.get("id"): j.get("name") for j in jobs}
    job_name.update({jid: pj["name"] for jid, pj in plugin_jobs.items()})
    backup_rows = []
    for b in raw.get("backups") or []:
        vms = per_backup.get(b.get("id"), {})
        repo_id = b.get("repositoryId")
        backup_rows.append({
            "name": b.get("name"), "job": job_name.get(backup_job_id(b, job_ids_by_name, job_name)),
            "created": _ts(b.get("creationTime")),
            "repository": b.get("repositoryName") or (nodes.get(repo_id) or {}).get("name"),
            "platform": backup_platform(b.get("platformName"), b.get("platformId"), b.get("jobType")),
            **(backup_totals(vms) if vms else {}),
            "objects": [{"name": v["name"], **backup_totals({k: v})}
                        for k, v in sorted(vms.items(), key=lambda kv: (_lc(kv[1]["name"]), kv[0]))]})
    backup_rows.sort(key=lambda x: (_lc(x["name"]), x["repository"] or ""))

    return {
        "generatedAt": dt.datetime.now().isoformat(timespec="seconds"),
        "vbr": {"name": vbr_name, "base": meta.get("base"), "apiVersion": meta.get("apiVersion"),
                "build": info.get("buildVersion"), "collectedAt": meta.get("collectedAt")},
        "nodes": list(nodes.values()),
        "links": list(links.values()),
        "jobs": job_rows,
        "backups": backup_rows,
        "warnings": warnings,
    }


def find_placement(names, place_by, place_short):
    """
    Placement of the first name that matches: full names first, then IP addresses, then short names.
    A short name is the weakest key: "vbr" is also the first label of an unrelated VM name like "VBR.WIN.Demo".
    """
    variants = [_lc(v) for nm in names for v in name_variants(nm) if v]
    ips = [v for v in variants if _is_ip(v)]
    full = [v for v in variants if not _is_ip(v)]
    return (next((place_by[v] for v in full + ips if v in place_by), None)
            or next((place_short[v] for v in full if v in place_short), None))


def apply_placement(nodes, by_name, place_by, place_short, add_node, conn_host):
    """Set placement / runsOn on every component; create ESXi nodes discovered via vCenter."""
    for n in list(nodes.values()):
        if n["kind"] not in ("backup", "em", "vone", "proxy", "repo", "server"):
            continue
        names = []
        if n["details"].get("Host"):
            names.append(n["details"]["Host"])
        if n["kind"] != "repo":
            names.append(n["name"])
        if n["kind"] == "backup" and conn_host and _lc(conn_host) not in LOCAL_HOSTS:
            names.append(conn_host)   # the address we connected to (an IP matches the VM's guest IP)
        hit = find_placement(names, place_by, place_short)
        if not hit:
            n["placement"] = {"host": None, "note": "Not found in the vSphere / Hyper-V inventory (physical or unmanaged)"}
            n["details"]["Runs on"] = "Unknown / physical"
            continue
        host = hit["host"]
        srv = by_name.get(_lc(host))
        hid = srv["id"] if srv and srv["id"] in nodes else None
        if not hid:
            hid = next((x["id"] for x in nodes.values() if x["kind"] in ("vi_host", "hv_host") and _lc(x["name"]) == _lc(host)), None)
        if not hid:
            hid = f"place:vi:{_lc(host)}"
            add_node(hid, "vi_host", host, "ESXi · discovered via vCenter")
        n["placement"] = {"host": host, "vm": hit.get("vm"), "source": hit["source"], "platform": hit["platform"]}
        n["runsOn"] = hid
        n["details"]["Runs on"] = f"{host} (VM: {hit.get('vm')})"
        n["details"]["Matched by"] = hit["source"]
        if pick_ips(hit.get("ips")):
            n["details"]["IP"] = f"{pick_ips(hit.get('ips'))} (VM guest)"

    # SOBR: summarize where the extents live (extents themselves are not drawn)
    for n in nodes.values():
        if n["kind"] != "sobr":
            continue
        parts, hosts = [], []
        for e in n.get("extents") or []:
            if e not in nodes:
                continue
            h = (nodes[e].get("placement") or {}).get("host") or "Unknown"
            parts.append(f"{nodes[e]['name']} → {h}")
            if h not in hosts:
                hosts.append(h)
        if parts:
            n["details"]["Extent hosts"] = "; ".join(parts)
            n["placeLabel"] = "Extents: " + " / ".join(h.split(".")[0] for h in hosts)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def render_html(model, path):
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "template.html"), encoding="utf-8") as f:
        tpl = f.read()
    data = json.dumps(model, ensure_ascii=False).replace("</", "<\\/")
    with open(path, "w", encoding="utf-8") as f:
        f.write(tpl.replace("/*__MODEL__*/null", data))


def main():
    ap = argparse.ArgumentParser(description="Scan Veeam Backup & Replication and draw the backup architecture")
    ap.add_argument("--host", help="VBR server FQDN or IP")
    ap.add_argument("--port", type=int, default=9419)
    ap.add_argument("--user", help="e.g. CORP\\veeam-admin")
    ap.add_argument("--password", help="not recommended on the command line; use VBR_PASSWORD or the prompt")
    ap.add_argument("--api-version", default="auto", help="x-api-version; detected automatically by default")
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification (VBR uses a self-signed cert by default)")
    ap.add_argument("--ca-bundle", help="custom CA bundle file")
    ap.add_argument("--em", action="append", metavar="HOST",
                    help="Enterprise Manager host (repeatable). VBR REST does not expose the EM registration.")
    ap.add_argument("--em-user", help="EM login, if different from --user")
    ap.add_argument("--em-password", help="EM password (default: same as VBR; or EM_PASSWORD)")
    ap.add_argument("--vcenter-user", help="query vCenter directly for component hosts (read-only account is enough)")
    ap.add_argument("--vcenter-password", help="vCenter password (or VCENTER_PASSWORD, or the prompt)")
    ap.add_argument("--vcenter", action="append", metavar="HOST",
                    help="vCenter address(es) to query; default: the vCenters registered in VBR")
    ap.add_argument("--placement-csv", help="manual component -> host map (columns Component,Host[,VM])")
    ap.add_argument("--from-raw", help="render from a previous vbr_raw.json instead of connecting")
    ap.add_argument("--lang", choices=["zh-TW", "en"], default="zh-TW",
                    help="default report language (viewers can switch it in the report)")
    ap.add_argument("--out", default="out", help="output folder (default ./out; one <VBR>_<time> subfolder per run)")
    ap.add_argument("--no-timestamp", action="store_true", help="write straight into --out, overwriting the last run")
    args = ap.parse_args()
    args.em_password = args.em_password or os.environ.get("EM_PASSWORD")

    if args.from_raw:
        with open(args.from_raw, encoding="utf-8") as f:
            raw = json.load(f)
        if args.em:  # allow adding EMs while re-rendering
            known = {_lc(e["host"]) for e in raw.get("enterpriseManagers") or []}
            raw.setdefault("enterpriseManagers", []).extend(
                {"host": h, "source": "Manual (--em)"} for h in args.em if _lc(h) not in known)
    else:
        if not args.host or not args.user:
            ap.error("--host and --user are required (or use --from-raw)")
        pw = args.password or os.environ.get("VBR_PASSWORD") or getpass.getpass(f"Password for {args.user}: ")
        client = VbrClient(args.host, args.port, args.insecure, args.ca_bundle)
        print(f"Connecting to {client.base} ...")
        ver = client.login(args.user, pw, args.api_version)
        print(f"Logged in (x-api-version={ver}). Scanning:")
        try:
            raw = collect(client)
        finally:
            client.logout()
        raw["_meta"]["hostName"] = canonical_host(args.host)   # kept for --from-raw
        if args.em and args.em_user and not args.em_password:
            # A different EM account usually has its own password; Enter keeps the VBR password
            args.em_password = getpass.getpass(f"Password for EM user {args.em_user} (Enter = same as VBR): ") or None
        collect_enterprise_managers(args, args.host, pw, raw)
        if args.vcenter_user:
            vc_pw = (args.vcenter_password or os.environ.get("VCENTER_PASSWORD")
                     or getpass.getpass(f"Password for vCenter user {args.vcenter_user}: "))
            print("Querying vCenter (component hosts):")
            collect_vcenter(args, raw, vc_pw)

    csv_rows = []
    if args.placement_csv:
        with open(args.placement_csv, encoding="utf-8-sig", newline="") as f:
            csv_rows = list(csv.DictReader(f))

    model = build_model(raw, csv_rows)
    model["lang"] = args.lang
    if not args.no_timestamp:
        short = re.sub(r'[\\/:*?"<>|\s]', "_", (model["vbr"]["name"] or "vbr").split(".")[0])
        args.out = os.path.join(args.out, f"{short}_{dt.datetime.now():%Y%m%d-%H%M%S}")
    os.makedirs(args.out, exist_ok=True)
    if not args.from_raw:
        with open(os.path.join(args.out, "vbr_raw.json"), "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out, "topology.json"), "w", encoding="utf-8") as f:
        json.dump(model, f, ensure_ascii=False, indent=2)
    html = os.path.join(args.out, "topology.html")
    render_html(model, html)
    kinds = {}
    for n in model["nodes"]:
        kinds[n["kind"]] = kinds.get(n["kind"], 0) + 1
    placed = sum(1 for n in model["nodes"] if (n.get("placement") or {}).get("host"))
    print("Nodes:", ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())))
    print(f"Data-flow links: {len(model['links'])}, components placed on a host: {placed}")
    for w in model["warnings"]:
        print("  Warning:", w)
    print(f"Done -> {html}")


if __name__ == "__main__":
    sys.exit(main())
