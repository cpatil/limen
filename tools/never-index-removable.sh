#!/bin/bash
# Marks newly mounted removable volumes so macOS never indexes them.
#
# Spotlight indexes a card the moment you insert it, writing its index onto the card
# itself. That competes with the import you actually want - on one measured session a
# card took 579 MB of writes while serving 474 MB of reads, and ran at 6.3 MB/s on
# hardware that had already demonstrated 85.8 MB/s.
#
# `.metadata_never_index` is the durable way to stop it: no root, it lives on the
# volume so it travels to any Mac, and it is undone by deleting the file. `mdutil -i
# off` needs a password and only applies to the machine it was run on.
#
# Only touches removable media (a card in a reader), never fixed disks and never the
# boot volume - disabling Spotlight there would break searching the machine.
set -u

log() { /usr/bin/logger -t never-index-removable "$1"; }

for volume in /Volumes/*; do
    [ -d "$volume" ] || continue
    # Never the boot volume, whatever it is called.
    [ "$(/usr/bin/stat -f %d "$volume" 2>/dev/null)" = "$(/usr/bin/stat -f %d / 2>/dev/null)" ] && continue
    [ -f "$volume/.metadata_never_index" ] && continue
    [ -w "$volume" ] || continue

    # Removable medium only, as reported by the storage stack rather than guessed
    # from the name. A network share has no such device and is skipped.
    device=$(/sbin/mount | /usr/bin/awk -v p="$volume" '$3 == p { print $1 }')
    case "$device" in /dev/disk*) ;; *) continue ;; esac
    removable=$(/usr/sbin/diskutil info "$device" 2>/dev/null \
                | /usr/bin/awk -F: '/Removable Media/ { gsub(/ /, "", $2); print $2 }')
    [ "$removable" = "Removable" ] || continue

    if /usr/bin/touch "$volume/.metadata_never_index" 2>/dev/null; then
        log "marked $volume as never-index"
    fi
done
