#!/bin/bash
# Runs whenever a volume appears or disappears, and does whatever Limen has been
# asked to do about memory cards.
#
# Two independent jobs, each switched on from Limen's Cards menu:
#
#   NeverIndexCards      write .metadata_never_index so Spotlight leaves the card
#                        alone. Spotlight indexes a card the moment it mounts and
#                        writes the index onto the card itself, which competes with
#                        the import you actually want - one measured session took
#                        579 MB of writes while serving 474 MB of reads.
#
#   LaunchOnCardInsert   open Limen, so the card's transfer is recorded from the
#                        first byte rather than from whenever you remember to look.
#
# Cards only. "Removable" on its own is far too broad: a mounted disk image reports
# itself as removable media, and was being marked on sight.
set -u

DOMAIN="local.limen"

pref() {  # pref <key> -> "1" when on
    /usr/bin/defaults read "$DOMAIN" "$1" 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

log() { /usr/bin/logger -t limen-card-watch "$1"; }

MARK=$(pref NeverIndexCards)
LAUNCH=$(pref LaunchOnCardInsert)
[ "$MARK" = "1" ] || [ "$LAUNCH" = "1" ] || exit 0

# Where Limen is. Recorded by the app itself each time it runs, because the agent
# cannot know whether it lives in /Applications, in a home folder, or somewhere else.
APP=$(/usr/bin/defaults read "$DOMAIN" AppPath 2>/dev/null)
[ -d "$APP" ] || APP="/Applications/Limen.app"

/usr/bin/find /Volumes -maxdepth 1 -mindepth 1 -type d -print 2>/dev/null |
while IFS= read -r volume; do
    # Never the boot volume, whatever it is called.
    [ "$(/usr/bin/stat -f %d "$volume" 2>/dev/null)" = "$(/usr/bin/stat -f %d / 2>/dev/null)" ] && continue

    device=$(/sbin/mount | /usr/bin/awk -v p="$volume" '$3 == p { print $1 }')
    case "$device" in /dev/disk*) ;; *) continue ;; esac

    info=$(/usr/sbin/diskutil info "$device" 2>/dev/null)
    protocol=$(printf '%s' "$info" | /usr/bin/awk -F: '/Protocol:/ { gsub(/^ +/, "", $2); print $2; exit }')
    removable=$(printf '%s' "$info" | /usr/bin/awk -F: '/Removable Media:/ { gsub(/^ +/, "", $2); print $2; exit }')

    # A real bus and a medium that comes out. This is what separates a card in a
    # reader from a disk image; a flash drive normally reports its media as Fixed.
    case "$protocol" in
        USB|"Secure Digital") ;;
        *) continue ;;
    esac
    [ "$removable" = "Removable" ] || continue

    if [ "$MARK" = "1" ] && [ ! -f "$volume/.metadata_never_index" ] && [ -w "$volume" ]; then
        if /usr/bin/touch "$volume/.metadata_never_index" 2>/dev/null; then
            log "marked $volume as never-index"
        else
            # macOS withholds removable volumes until an app is granted them, and a
            # background job is never the one asked.
            log "could not mark $volume - removable volume access not granted"
        fi
    fi

    if [ "$LAUNCH" = "1" ]; then
        # Harmless when it is already up: Limen allows one instance, so this brings
        # the running copy forward instead of starting a second.
        /usr/bin/open "$APP" 2>/dev/null && log "opened Limen for $volume"
    fi
done
