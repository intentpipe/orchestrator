#!/usr/bin/env python3
"""Static file server that forbids caching — shared by every project's web preview.

Plain `python3 -m http.server` sends no Cache-Control, so Cloudflare applies its
default edge caching to static assets (.js etc.) and keeps serving a STALE
main.dart.js / flutter_bootstrap.js for hours after a rebuild — even in an
Incognito window, because the staleness lives at the edge, not in the browser.

Flutter's web entry files use fixed (non-hashed) names, so the cache key never
changes across builds. We send `no-store` on every response: Cloudflare will not
cache a response marked no-store/no-cache/private, so every relaunch propagates
immediately. Previews are low-traffic, so losing edge caching costs nothing.

This lives in the orchestrator (not any one project) because the preview-serving
mechanism is a box-level deployment concern shared across projects — the same
cloudflared tunnel fronts them all. Each project's <name>-dev.sh reaches it
through preview-lib.sh in this directory.

Usage: serve-nocache.py <port> <directory>
"""
import sys
import http.server
import socketserver

port = int(sys.argv[1])
directory = sys.argv[2]


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, *args):  # keep the preview log to warnings/errors, not every GET
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("", port), NoCacheHandler) as httpd:
    httpd.serve_forever()
