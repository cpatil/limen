#!/bin/bash
# Marks newly mounted memory cards so macOS never indexes them.
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
# Only touches a card in a reader: never fixed disks, never the boot volume
# (disabling Spotlight there would break searching the machine), and never a mounted
# disk image, which reports itself as removable and was being marked on sight.
set -u

log() { /usr/bin/logger -t never-index-removable "$1"; }

for volume in /Volumes/*; do
    [ -d "$volume" ] || continue
    # Never the boot volume, whatever it is called.
    [ "$(/usr/bin/stat -f %d "$volume" 2>/dev/null)" = "$(/usr/bin/stat -f %d / 2>/dev/null)" ] && continue
    [ -f "$volume/.metadata_never_index" ] && continue
    [ -w "$volume" ] || continue

    # Cards only. Three facts have to line up, because "removable" alone is far too
    # broad: a mounted disk image reports itself as removable media and would be
    # marked on sight, which is not what anyone means by "my SD cards".
    #
    #   protocol            USB or Secure Digital - a real bus, not a disk image
    #   removable media     the medium comes out of the device
    #
    # A USB flash drive normally reports its media as Fixed and so is skipped. One
    # that lies about that will still be marked; there is no further signal to use.
    device=$(/sbin/mount | /usr/bin/awk -v p="$volume" '$3 == p { print $1 }')
    case "$device" in /dev/disk*) ;; *) continue ;; esac

    info=$(/usr/sbin/diskutil info "$device" 2>/dev/null)
    protocol=$(printf '%s' "$info" | /usr/bin/awk -F: '/Protocol:/ { gsub(/^ +/, "", $2); print $2; exit }')
    removable=$(printf '%s' "$info" | /usr/bin/awk -F: '/Removable Media:/ { gsub(/^ +/, "", $2); print $2; exit }')

    case "$protocol" in
        USB|"Secure Digital") ;;
        *) continue ;;
    esac
    [ "$removable" = "Removable" ] || continue

    if /usr/bin/touch "$volume/.metadata_never_index" 2>/dev/null; then
        log "marked $volume as never-index"
    fi
done
