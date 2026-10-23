#!/usr/bin/env bash
# Serves a tile directory from tools/tiles/build.sh over HTTP with CORS, for the game
# (?tiles=http://localhost:8714/{z}/{x}/{y}.pbf) and the tests (ROAM_TILES=...).
# Usage: tools/tiles/serve.sh DIR [PORT]
set -euo pipefail
dir=${1:?usage: tools/tiles/serve.sh DIR [PORT]}
port=${2:-8714}
cd "$dir"
exec python3 -c '
import http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
	extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".pbf": "application/x-protobuf"}
	def end_headers(self):
		self.send_header("Access-Control-Allow-Origin", "*")
		super().end_headers()
http.server.ThreadingHTTPServer(("", int(sys.argv[1])), H).serve_forever()
' "$port"
