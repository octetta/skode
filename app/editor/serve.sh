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
echo " Press Ctrl+C to stop."
echo "=========================================================="
echo ""

python3 -m http.server "$PORT"
