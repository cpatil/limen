#!/bin/bash
# Builds and runs the checks in Tests/. No Xcode, same toolchain as build.sh.
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=$(ls Sources/*.swift | grep -v 'Sources/main.swift')
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "==> Building tests"
swiftc -O -framework Cocoa -framework IOKit -framework SystemConfiguration \
    $SOURCES Tests/main.swift -o "$OUT/tests"

# Twice: the palette differs between appearances, and a colour that works on one
# ground can be unreadable on the other. A single pass could only ever check half of
# what ships.
status=0
for appearance in light dark; do
    echo "==> Running ($appearance)"
    LIMEN_APPEARANCE="$appearance" "$OUT/tests" || status=1
done
exit $status
