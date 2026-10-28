"""
Minimal HTTPS mock of the VBR REST API (and the EM REST API) for offline tests.

  python3 test/mock_vbr_rest.py <cert.pem> <key.pem> <vbr_port> <em_port> [<vcenter_port>]

Env: MOCK_IP_PROXY=1 registers one proxy by IP; MOCK_VC_OLD=1 makes vCenter serve only /rest.

Serves the objects from sample_raw.json plus a legacy vSphere inventory.
"""
import json
import os
import ssl
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = json.load(open(os.path.join(HERE, "..", "sample_raw.json"), encoding="utf-8"))
if os.environ.get("MOCK_IP_PROXY"):
    RAW["proxies"][0]["name"] = "10.0.0.11"
    next(m for m in RAW["managedServers"] if m["id"] == "ms-px1")["name"] = "10.0.0.11"
PATHS = {
    "/api/v1/serverInfo": "serverInfo",
    "/api/v1/backupInfrastructure/managedServers": "managedServers",
    "/api/v1/backupInfrastructure/proxies": "proxies",
    "/api/v1/backupInfrastructure/repositories": "repositories",
    "/api/v1/backupInfrastructure/repositories/states": "repositoryStates",
    "/api/v1/backupInfrastructure/scaleOutRepositories": "scaleOutRepositories",
    "/api/v1/agents/protectionGroups": "protectionGroups",
    "/api/v1/jobs": "jobs",
    "/api/v1/backups": "backups",
}
# vCenter inventory: host -> VMs
INVENTORY = {"esx01.corp.local": ["vbr01", "em01", "vbrpx01"],
             "esx02.corp.local": ["vbrpx02.corp.local", "lhr01", "app-sql01"]}


class VbrHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send_json(self, obj, code=200, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def page(self, items, q):
        skip, limit = int(q.get("skip", ["0"])[0]), int(q.get("limit", ["500"])[0])
        self.send_json({"data": items[skip:skip + limit], "pagination": {"total": len(items), "skip": skip, "count": len(items[skip:skip + limit])}})

    def do_POST(self):
        if self.path == "/api/oauth2/token":
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            return self.send_json({"access_token": "t"}) if self.headers.get("x-api-version") == "1.2-rev1" else self.send_json({}, 400)
        if self.path == "/api/oauth2/logout":
            return self.send_json({})
        if self.path == "/api/v1/inventory/vcsa01.corp.local" and not os.environ.get("MOCK_NO_BROWSER"):
            # New inventory browser: flat object list with parent references
            spec = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            items = [{"inventoryObject": {"type": "Cluster", "name": "Prod", "objectId": "domain-c1"}}]
            for i, (h, vms) in enumerate(INVENTORY.items()):
                items.append({"inventoryObject": {"type": "Host", "name": h, "objectId": f"host-{i}", "parentId": "domain-c1"}})
                items += [{"inventoryObject": {"type": "VirtualMachine", "name": vm, "objectId": f"vm-{i}-{j}", "parentId": f"host-{i}"}}
                          for j, vm in enumerate(vms)]
            p = spec.get("pagination", {})
            skip, limit = p.get("skip", 0), p.get("limit", 500)
            return self.send_json({"data": items[skip:skip + limit], "pagination": {"total": len(items)}})
        self.send_json({}, 404)

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer t":
            return self.send_json({}, 401)
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path in PATHS:
            v = RAW[PATHS[u.path]]
            return self.page(v, q) if isinstance(v, list) else self.send_json(v)
        if u.path == "/api/v1/inventory/vmware/hosts/vcsa01.corp.local" and not os.environ.get("MOCK_NO_LEGACY"):
            t = q.get("typeFilter", [""])[0]
            if t == "Host":
                items = [{"type": "Host", "hostName": "vcsa01.corp.local", "name": h} for h in INVENTORY]
            elif "parentContainerNameFilter" in q and os.environ.get("MOCK_EMPTY_PARENT"):
                items = []   # like v13: VMs are not direct children of hosts
            elif "parentContainerNameFilter" in q:
                parent = q["parentContainerNameFilter"][0]
                items = [{"type": "VirtualMachine", "hostName": "vcsa01.corp.local", "name": vm} for vm in INVENTORY.get(parent, [])]
            else:
                items = [{"type": "VirtualMachine", "hostName": "vcsa01.corp.local", "name": vm} for vms in INVENTORY.values() for vm in vms]
            return self.page(items, q)
        self.send_json({}, 404)


class EmHandler(VbrHandler):
    def do_POST(self):
        if self.path.startswith("/api/sessionMngr/") and self.headers.get("Authorization", "").startswith("Basic "):
            return self.send_json({}, 201, {"X-RestSvcSessionId": "sid"})
        self.send_json({}, 401)

    def do_GET(self):
        if self.headers.get("X-RestSvcSessionId") != "sid":
            return self.send_json({}, 401)
        if self.path.startswith("/api/backupServers"):
            return self.send_json({"BackupServers": [{"Name": "vbr01.corp.local"}, {"Name": "vbr-dr.corp.local"}]})
        self.send_json({}, 404)


# vCenter: VM names differ from guest hostnames on purpose, to test guest matching
VC_HOSTS = {"host-1": "esx01.corp.local", "host-2": "esx02.corp.local", "host-3": "esx03.corp.local"}
VC_VMS = [  # id, name, host id, power, guest hostname, ips
    ("vm-1", "VBR-Server", "host-1", "POWERED_ON", "vbr01.corp.local", ["10.0.0.10"]),
    ("vm-2", "EM-01", "host-1", "POWERED_ON", "em01", ["10.0.0.20"]),
    ("vm-3", "proxy-a", "host-2", "POWERED_ON", None, ["10.0.0.11"]),
    ("vm-4", "vbrpx02.corp.local", "host-2", "POWERED_ON", "vbrpx02.corp.local", ["10.0.0.12"]),
    ("vm-5", "LHR-01", "host-3", "POWERED_ON", "lhr01.corp.local", ["10.0.0.31"]),
    ("vm-6", "old-template", "host-3", "POWERED_OFF", None, []),
]


class VCenterHandler(VbrHandler):
    def wrap(self, obj):
        return {"value": obj} if self.path.startswith("/rest") else obj

    def do_POST(self):
        old = bool(os.environ.get("MOCK_VC_OLD"))
        if self.path == "/api/session" and old:
            return self.send_json({}, 404)
        if self.path in ("/api/session", "/rest/com/vmware/cis/session"):
            ok = self.headers.get("Authorization", "").startswith("Basic ")
            return self.send_json(self.wrap("vc-sid"), 201) if ok else self.send_json({}, 401)
        self.send_json({}, 404)

    def do_DELETE(self):
        self.send_json({})

    def do_GET(self):
        if self.headers.get("vmware-api-session-id") != "vc-sid":
            return self.send_json({}, 401)
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path.replace("/rest/", "/api/", 1)
        if p == "/api/vcenter/host":
            return self.send_json(self.wrap([{"host": k, "name": v, "connection_state": "CONNECTED", "power_state": "POWERED_ON"}
                                             for k, v in VC_HOSTS.items()]))
        if p == "/api/vcenter/vm":
            hid = (q.get("hosts") or q.get("filter.hosts") or [""])[0]
            return self.send_json(self.wrap([{"vm": i, "name": n, "power_state": pw} for i, n, h, pw, _, _ in VC_VMS if h == hid]))
        for i, n, h, pw, gh, ips in VC_VMS:
            if p == f"/api/vcenter/vm/{i}/guest/identity":
                if pw != "POWERED_ON":
                    return self.send_json({}, 503)
                return self.send_json(self.wrap({"host_name": gh or "", "ip_address": ips[0] if ips else None}))
            if p == f"/api/vcenter/vm/{i}/guest/networking/interfaces":
                return self.send_json([{"ip": {"ip_addresses": [{"ip_address": a} for a in ips]}}])
        self.send_json({}, 404)


def serve(handler, port, ctx):
    srv = ThreadingHTTPServer(("127.0.0.1", port), handler)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if __name__ == "__main__":
    cert, key, vbr_port, em_port = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    if len(sys.argv) > 5:
        threading.Thread(target=serve, args=(VCenterHandler, int(sys.argv[5]), ctx), daemon=True).start()
    threading.Thread(target=serve, args=(EmHandler, em_port, ctx), daemon=True).start()
    serve(VbrHandler, vbr_port, ctx)
