#!/bin/bash
# Renders the hover card offscreen into an output directory (default build/cards),
# so a layout change can be looked at rather than only asserted about.
#
# Compiled against Sources/ the same way test.sh is: this needs the real MagnifierView,
# so unlike tools/make-icon.swift it cannot run as a standalone `swift` script.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/cards}"
SOURCES=$(ls Sources/*.swift | grep -v 'Sources/main.swift')
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT

echo "==> Building renderer"
swiftc -O -framework Cocoa -framework IOKit -framework SystemConfiguration \
    $SOURCES tools/render-card/main.swift -o "$BIN/render-card"

echo "==> Rendering into $OUT"
"$BIN/render-card" "$OUT"
