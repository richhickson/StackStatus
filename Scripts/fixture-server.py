#!/usr/bin/env python3
"""A fake Atlassian Statuspage for testing notifications end to end.

    Scripts/fixture-server.py [port]            default port 8099

Then add a vendor in StackStatus with base URL http://127.0.0.1:8099 and
platform "Atlassian Statuspage". Change the simulated state with:

    curl http://127.0.0.1:8099/_set/minor      (none, minor, major, critical, maintenance)

Two polls later (or one for critical) the app notifies; set it back to
"none" and two polls later it notifies the resolution with the duration.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = {"indicator": "none", "since": time.time(), "etag": 1}
DESCRIPTIONS = {
    "none": "All Systems Operational", "minor": "Minor Service Outage", "major": "Partial System Outage",
    "critical": "Major System Outage", "maintenance": "Service Under Maintenance",
}

def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(t))

class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", f'W/"{STATE["etag"]}"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        page = {"id": "fixture", "name": "Fixture", "url": f"http://127.0.0.1:{PORT}", "updated_at": iso(time.time())}
        if self.path.startswith("/_set/"):
            ind = self.path.split("/")[2]
            if ind not in DESCRIPTIONS:
                return self._json({"error": "unknown indicator"}, 400)
            STATE.update(indicator=ind, since=time.time(), etag=STATE["etag"] + 1)
            return self._json({"ok": True, "indicator": ind})
        if self.path == "/api/v2/status.json":
            if self.headers.get("If-None-Match") == f'W/"{STATE["etag"]}"':
                self.send_response(304); self.end_headers(); return
            return self._json({"page": page, "status": {"indicator": STATE["indicator"], "description": DESCRIPTIONS[STATE["indicator"]]}})
        incident = {
            "id": "fixture-1", "name": f"Simulated {STATE['indicator']} incident", "status": "identified",
            "impact": STATE["indicator"], "shortlink": f"http://127.0.0.1:{PORT}/incidents/fixture-1",
            "started_at": iso(STATE["since"]), "updated_at": iso(time.time()), "resolved_at": None, "incident_updates": [],
        }
        if self.path == "/api/v2/incidents/unresolved.json":
            return self._json({"page": page, "incidents": [] if STATE["indicator"] in ("none", "maintenance") else [incident]})
        if self.path == "/api/v2/scheduled-maintenances/active.json":
            m = dict(incident, impact="maintenance", status="in_progress", name="Simulated maintenance")
            return self._json({"page": page, "scheduled_maintenances": [m] if STATE["indicator"] == "maintenance" else []})
        self._json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("If-None-Match", "-"), fmt % args))

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
print(f"fixture statuspage on http://127.0.0.1:{PORT}  (curl http://127.0.0.1:{PORT}/_set/major)")
HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
