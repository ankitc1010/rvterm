#!/usr/bin/env python3
"""Serves the built terminal (zig-out/web) on the LAN for the TV, plus the capability probe.

Usage: python3 serve.py [port]   (default 8080)
  /         the terminal (run `zig build` first)
  /probe/   the capability probe; its reports land in probe/reports/
"""
import http.server
import json
import os
import socket
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(ROOT, "zig-out", "web")
PROBE = os.path.join(ROOT, "probe")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm"}

    def translate_path(self, path):
        if path.startswith("/probe/"):
            rel = path[len("/probe/"):].split("?", 1)[0]
            return os.path.join(PROBE, os.path.normpath("/" + rel).lstrip("/"))
        return super().translate_path(path)

    def end_headers(self):
        # Always serve the latest build; TV browsers cache aggressively.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        if self.path == "/log":
            self.append_log()
            return
        if self.path not in ("/report", "/probe/report"):
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            data = json.loads(body)
        except ValueError:
            self.send_error(400)
            return
        reports = os.path.join(PROBE, "reports")
        os.makedirs(reports, exist_ok=True)
        name = "report-%s.json" % self.client_address[0].replace(":", "_")
        with open(os.path.join(reports, name), "w") as f:
            json.dump(data, f, indent=2)
        self.send_response(204)
        self.end_headers()


    def append_log(self):
        # Debug events from the terminal opened with ?debug, one JSON object per line.
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            entries = json.loads(body)
        except ValueError:
            self.send_error(400)
            return
        reports = os.path.join(PROBE, "reports")
        os.makedirs(reports, exist_ok=True)
        name = "log-%s.jsonl" % self.client_address[0].replace(":", "_")
        with open(os.path.join(reports, name), "a") as f:
            for entry in entries:
                f.write(json.dumps(entry) + "\n")
        self.send_response(204)
        self.end_headers()


def lan_ip():
    # A UDP connect sends no packets; it only picks the outgoing interface.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


if __name__ == "__main__":
    handler = lambda *args, **kwargs: Handler(*args, directory=WEB, **kwargs)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    print("Terminal: http://%s:%d/    Probe: http://%s:%d/probe/" % (lan_ip(), PORT, lan_ip(), PORT), flush=True)
    server.serve_forever()
