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

echo "==> Running"
"$OUT/tests"
