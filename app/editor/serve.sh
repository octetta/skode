#!/usr/bin/env bash
set -e

PORT="${1:-8000}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building Skode Voice Editor (Lustre 5 / JS)..."
cd "$DIR"
gleam build --target javascript

echo ""
echo "=========================================================="
echo " Skode Voice Editor live at http://localhost:${PORT}"
echo " Serving with real Pulp 0.85.0 WASM engine (COOP/COEP enabled)"
echo " Press Ctrl+C to stop."
echo "=========================================================="
echo ""

python3 -c '
from http import server
import sys

class ThreadedHTTPServer(server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
server.test(HandlerClass=ThreadedHTTPServer, port=port)
' "$PORT"
