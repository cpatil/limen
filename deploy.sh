#!/bin/bash
# Builds and installs Limen.app on a remote Mac over SSH, then launches it.
# Usage: ./deploy.sh <ssh-host>
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: ./deploy.sh <ssh-host>" >&2; exit 2; }
APP_NAME="Limen"

./build.sh

echo "==> Packaging"
TARBALL="$(mktemp -t limen).tgz"
tar czf "$TARBALL" -C build "$APP_NAME.app"

echo "==> Copying to $HOST"
scp -q "$TARBALL" "$HOST:/tmp/limen.tgz"
rm -f "$TARBALL"

# Install to /Applications so the app shows up where people actually look for it.
# On a standard Mac that directory is group-writable by admin users, so no password
# is needed; fall back to the per-user ~/Applications when it is not writable.
DEST="$(ssh "$HOST" '[ -w /Applications ] && echo /Applications || echo "$HOME/Applications"')"
echo "==> Installing to $DEST on $HOST"

# Replacing a bundle in place leaves LaunchServices pointing at the old copy, after which
# `open` fails with kLSNoExecutableErr even though the bundle is perfectly valid. Explicitly
# unregister the old path before swapping, and re-register the new one afterwards.
ssh "$HOST" "
    set -e
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    DEST='$DEST'
    pkill -f '$APP_NAME' 2>/dev/null || true
    sleep 1
    mkdir -p \"\$DEST\"
    for OLD in \"\$DEST/$APP_NAME.app\" \"\$HOME/Applications/$APP_NAME.app\"; do
        [ -e \"\$OLD\" ] || continue
        \"\$LSREG\" -u \"\$OLD\" 2>/dev/null || true
        rm -rf \"\$OLD\"
    done
    tar xzf /tmp/limen.tgz -C \"\$DEST\"
    rm -f /tmp/limen.tgz
    xattr -dr com.apple.quarantine \"\$DEST/$APP_NAME.app\" 2>/dev/null || true
    \"\$LSREG\" -f -R \"\$DEST/$APP_NAME.app\" 2>/dev/null || true
    sleep 1
    open \"\$DEST/$APP_NAME.app\"
"

echo "==> Running on $HOST at $DEST/$APP_NAME.app"
