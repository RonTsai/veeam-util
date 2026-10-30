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
API_VERSIONS = ["1.3-rev1", "1.3-rev0", "1.2-rev1", "1.2-rev0",
                "1.1-rev2", "1.1-rev1", "1.1-rev0", "1.0-rev2", "1.0-rev1"]

# Endpoints to collect: key -> (path, paginated)
ENDPOINTS = {
    "serverInfo":           ("/api/v1/serverInfo", False),
    "managedServers":       ("/api/v1/backupInfrastructure/managedServers", True),
    "proxies":              ("/api/v1/backupInfrastructure/proxies", True),
    "repositories":         ("/api/v1/backupInfrastructure/repositories", True),
    "repositoryStates":     ("/api/v1/backupInfrastructure/repositories/states", True),
    "scaleOutRepositories": ("/api/v1/backupInfrastructure/scaleOutRepositories", True),
    "wanAccelerators":      ("/api/v1/backupInfrastructure/wanAccelerators", True),
    "protectionGroups":     ("/api/v1/agents/protectionGroups", True),
    "jobs":                 ("/api/v1/jobs", True),
    "backups":              ("/api/v1/backups", True),
}

EM_REST_PORT = int(os.environ.get("EM_REST_PORT", "9398"))  # override for testing only


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
    raw["inventory"] = collect_inventory(client, raw)
    return raw


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
    for o in j.get("objects") or []:
        if "objectStorageServerId" in o:
            path = "/".join(x for x in (o.get("container"), o.get("path")) if x and x != "/")
            add(path, "Object storage", names.get(o.get("objectStorageServerId")))
            masks = o.get("exclusionPathMask")
        else:
            path = o.get("path")
            add(path, "File share", names.get(o.get("fileServerId")))
            masks = o.get("exclusionMask")
        for m in masks or []:
            add(m, "Exclusion mask", path, excluded=True)
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
                inventory[name] = {"method": "legacy", "vmsByHost": vms_by_host}
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
                     "amazonsnowballedge", "s3"}
SHARE_REPO_TYPES = {"smb", "nfs"}
DEDUP_REPO_TYPES = {"ddboost", "exagrid", "hpstoreonce", "quantum", "infinidat", "fujitsu"}


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
    Build a lookup: lowercase VM name / short name / IP -> placement info.
    Priority: manual CSV, then vCenter REST (guest hostname / IP), then the VBR inventory.
    """
    index = {}

    def add(key, info):
        k = _lc(key)
        if k and k not in index:
            index[k] = info

    def add_names(name, info):
        if not name:
            return
        add(name, info)
        if not _is_ip(name):
            add(name.split(".")[0], info)

    for r in csv_rows:
        if r.get("Component") and r.get("Host"):
            add_names(r["Component"], {"host": r["Host"], "vm": r.get("VM"), "source": "Manual CSV", "platform": "vi"})

    for vc, data in (raw.get("vcenter") or {}).items():
        src = f"vCenter REST ({vc})"
        for vm in data.get("vms") or []:
            if not vm.get("host"):
                continue
            info = {"host": vm["host"], "vm": vm.get("name"), "source": src, "platform": "vi"}
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
    return index


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
    vbr_name = info.get("name") or urllib.parse.urlparse(meta.get("base", "")).hostname or "VBR"
    add_node("vbr", "backup", vbr_name, f"Backup server · v{info.get('buildVersion', '?')}",
             details={"Build": info.get("buildVersion"), "Patches": ", ".join(info.get("patches") or []),
                      "Database": info.get("databaseVendor"), "VBR ID": info.get("vbrId")})

    # ---- Enterprise Manager (management tier, drawn next to the backup server)
    for em in raw.get("enterpriseManagers") or []:
        reg = em.get("registered")
        is_reg = None if reg is None else any(_lc(r) in (_lc(vbr_name), _lc(vbr_name).split(".")[0]) or
                                               _lc(r).split(".")[0] == _lc(vbr_name).split(".")[0] for r in reg)
        sub = "Enterprise Manager"
        if _lc(em["host"]) == _lc(urllib.parse.urlparse(meta.get("base", "")).hostname) or _lc(em["host"]) == _lc(vbr_name):
            sub += " · same host as VBR"
        add_node(f"mgmt:em:{_lc(em['host'])}", "em", em["host"], sub, details={
            "Source": em.get("source"), "URL": f"https://{em['host']}:9443",
            "Registered backup servers": ", ".join(reg) if reg else None,
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
        if _lc(s.get("name")) == _lc(vbr_name):
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
                              "Data Mover": "On-host proxy (Veeam Data Mover Service)"})
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
                 "GeneralPurposeProxy": "General-purpose proxy"}.get(t, t)
        add_node(p["id"], "proxy", p.get("name") or host_name(hid) or "proxy", label, badges=["M"],
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
        t = r.get("type", "")
        st = states.get(r["id"], {})
        hid = r.get("hostId") or (r.get("repository") or {}).get("hostId")
        gateways = find_all(r.get("share") or {}, "gatewayServerIds")
        gw_names = [host_name(g) for gl in gateways for g in (gl or []) if host_name(g)]
        used_hosts.add(hid)
        for gl in gateways:
            used_hosts.update(gl or [])
        tl = _lc(t)
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
        details = {"Type": t, "Host": host_name(hid) or st.get("hostName"),
                   "Path": st.get("path") or (r.get("repository") or {}).get("path")
                   or (r.get("share") or {}).get("sharePath") or find_first(r, "bucketName"),
                   "Gateway": ", ".join(gw_names) or None,
                   "Capacity": fmt_gb(cap), "Free": fmt_gb(free),
                   "Description": r.get("description")}
        if r["id"] in sobr_extents:
            details["SOBR extent of"] = sobr_extents[r["id"]]
        n = add_node(r["id"], kind, r.get("name"), label, badges=badges, details=details)
        if isinstance(cap, (int, float)) and cap:
            n["usage"] = round(1 - (free or 0) / cap, 3)

    for sb in raw.get("scaleOutRepositories") or []:
        perf = sb.get("performanceTier") or {}
        ext = perf.get("performanceExtents") or perf.get("extents") or []
        ext_names = [(nodes.get(e.get("id")) or {}).get("name") or e.get("name") for e in ext]
        cap_tier = sb.get("capacityTier") or {}
        arch_tier = sb.get("archiveTier") or {}
        add_node(sb["id"], "sobr", sb.get("name"), f"Scale-out repository · {len(ext)} extents",
                 details={"Performance tier": ", ".join(filter(None, ext_names)),
                          "Capacity tier": "Enabled" if cap_tier.get("isEnabled") or cap_tier.get("enabled") else "—",
                          "Archive tier": "Enabled" if arch_tier.get("isEnabled") or arch_tier.get("enabled") else "—",
                          "Description": sb.get("description")})
        nodes[sb["id"]]["extents"] = [e.get("id") for e in ext]
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
    for j in jobs:
        jt = j.get("type", "")
        jtl = _lc(jt)
        name = j.get("name")
        storage = j.get("storage") or {}
        repo = storage.get("backupRepositoryId") or next(iter(find_all(j, "backupRepositoryId")), None)
        proxy_cfg = storage.get("backupProxies") or next(iter(find_all(j, "backupProxies")), {}) or {}
        sel_proxies = [p for p in (proxy_cfg.get("proxyIds") or []) if p in nodes]
        auto = proxy_cfg.get("autoSelection", not sel_proxies)
        includes = (j.get("virtualMachines") or {}).get("includes") or []
        hosts = set()
        for inc in includes:
            obj = _obj(inc)
            if obj.get("hostName"):
                hosts.add(obj["hostName"])
        job_rows.append({"name": name, "type": jt, "disabled": j.get("isDisabled"),
                         "repository": (nodes.get(repo) or {}).get("name"),
                         "sources": sorted(hosts), "proxies": "Automatic" if auto and not sel_proxies
                         else ", ".join(nodes[p]["name"] for p in sel_proxies),
                         "objects": job_objects(j, server_names)})
        if repo not in nodes:
            continue
        label = name + (" (disabled)" if j.get("isDisabled") else "")
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
        elif "agent" in jtl or "computer" in jtl:
            pg_ids = [i for i in find_all(j, "id") if isinstance(i, str) and nodes.get(i, {}).get("kind") == "agent"]
            if not pg_ids:
                pg_ids = [add_node("agents", "agent", "Veeam Agents", "Physical / virtual servers",
                                   badges=["A"])["id"]]
            for pg in pg_ids:
                add_link(pg, repo, label)
        elif "file" in jtl or "nas" in jtl or "objectstorage" in jtl or "unstructured" in jtl:
            px = sel_proxies or proxies_by_type.get("GeneralPurposeProxy", [])
            for p in px:
                add_link(p, repo, label, "data" if sel_proxies else "auto")
        elif "copy" in jtl:
            src_repo = j.get("sourceRepositoryId") or next(iter(find_all(j.get("source") or {}, "backupRepositoryId")), None)
            if src_repo in nodes:
                add_link(src_repo, repo, label, "copy")

    # Agent backups from /backups (older API versions have no agent jobs)
    linked_repos_from_agents = {l["target"] for l in links.values() if nodes[l["source"]]["kind"] == "agent"}
    for b in raw.get("backups") or []:
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
    place_by = placement_index(raw, csv_rows)
    if place_by:
        apply_placement(nodes, by_name, place_by, add_node, vbr_name)
    elif raw.get("inventory"):
        warnings.append("The vSphere inventory was read, but it has no VM-to-host relation; component hosts "
                        "not matched (use the PowerShell version or --placement-csv)")
    elif any(n["kind"] == "vi_host" for n in nodes.values()):
        warnings.append("vSphere inventory unavailable; component hosts not matched (use --placement-csv)")

    for n in nodes.values():
        n["details"] = {k: v for k, v in n["details"].items() if v not in (None, "", [])}

    for key, err in (raw.get("_errors") or {}).items():
        warnings.append(f"{key}: {err}")

    return {
        "generatedAt": dt.datetime.now().isoformat(timespec="seconds"),
        "vbr": {"name": vbr_name, "base": meta.get("base"), "apiVersion": meta.get("apiVersion"),
                "build": info.get("buildVersion"), "collectedAt": meta.get("collectedAt")},
        "nodes": list(nodes.values()),
        "links": list(links.values()),
        "jobs": job_rows,
        "warnings": warnings,
    }


def apply_placement(nodes, by_name, place_by, add_node, vbr_name):
    """Set placement / runsOn on every component; create ESXi nodes discovered via vCenter."""
    for n in list(nodes.values()):
        if n["kind"] not in ("backup", "em", "vone", "proxy", "repo", "server"):
            continue
        names = []
        if n["details"].get("Host"):
            names.append(n["details"]["Host"])
        if n["kind"] != "repo":
            names.append(n["name"])
        if n["kind"] == "backup":
            names.append(vbr_name)
        hit = None
        for nm in names:
            hit = next((place_by[_lc(v)] for v in name_variants(nm) if _lc(v) in place_by), None)
            if hit:
                break
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
