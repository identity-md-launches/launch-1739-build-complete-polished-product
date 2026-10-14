#!/usr/bin/env python3
"""Serve the committed dashboard without npm, a bundler, or network installation."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=8080)
parser.add_argument("--host", default="127.0.0.1")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1] / "web"


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


server = ThreadingHTTPServer((args.host, args.port), partial(Handler, directory=str(root)))
print(f"AgentSkill: http://{args.host}:{args.port}", flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    server.server_close()
