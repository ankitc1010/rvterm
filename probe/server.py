#!/usr/bin/env python3
"""Serves the VIDAA probe page on the LAN and saves the reports the TV posts back.

Usage: python3 server.py [port]   (default 8080)
Reports land in reports/report-<client-ip>.json, overwritten with each update.
"""
import http.server
import json
import os
import socket
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPORTS = os.path.join(ROOT, "reports")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        # TV browsers cache aggressively; always serve the latest probe.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_POST(self):
        if self.path != "/report":
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            data = json.loads(body)
        except ValueError:
            self.send_error(400)
            return
        os.makedirs(REPORTS, exist_ok=True)
        name = "report-%s.json" % self.client_address[0].replace(":", "_")
        with open(os.path.join(REPORTS, name), "w") as f:
            json.dump(data, f, indent=2)
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
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Open this on the TV browser:  http://%s:%d/" % (lan_ip(), PORT))
    print("Reports are saved to %s" % REPORTS)
    server.serve_forever()
