# Limen

Live read/write rates for every storage device and network interface on a Mac, and
what's actually limiting each one.

Activity Monitor won't show you the throughput of one USB device, and nothing in macOS
will tell you why a card import is slow. This does both.

![Limen](docs/limen.png)

## Build

```bash
./build.sh          # -> build/Limen.app
open build/Limen.app
```

AppKit, no SwiftUI, no Xcode, no package manager. Universal `x86_64 + arm64` with a
10.14 deployment target, so it runs on a 2015 12" MacBook as well as current hardware.
`./deploy.sh <ssh-host>` builds and installs it on another Mac over SSH.

## Where the numbers come from

Storage throughput is `IOBlockStorageDriver`'s `Statistics` dictionary. Network is
`sysctl(NET_RT_IFLIST2)` with the 64-bit `if_data64` — the easier `getifaddrs` path
gives you 32-bit counters that wrap every 4 GB.

The headline network total counts hardware interfaces only. A VPN tunnel or a bridge
carries traffic that is *also* counted on the physical interface underneath it, so
summing everything reports roughly double.

Three things it deliberately can't do:

- macOS keeps no general per-USB byte counters, so a keyboard or an audio interface
  gets its link speed and nothing else. Those rows say so instead of drawing a flat
  line that looks like an idle device.
- Processes owned by other users need root, so their I/O is missing rather than
  misattributed.
- Wi-Fi's reported link rate is fiction — mine claimed 304 Mbit/s while doing 30.2,
  and I logged a peak above its own stated ceiling. `ifi_baudrate` is distrusted for
  anything SystemConfiguration calls wireless; those rows measure against their own
  observed best instead.

## Rates need a denominator

"111 MB/s" means nothing alone, so every row says what it's comparable to and how much
of its link it's using:

| Rate | Link | Shown as |
|---|---|---|
| 35 MB/s flash drive | USB 2.0 | 87.5% link utilization · ≈ USB 2.0 |
| 111 MB/s hard disk | USB 3.0 | 24.7% · ≈ Gigabit Ethernet |
| 420 MB/s SSD | USB 3.0 | 93.3% · ≈ USB 3.0 |

First and third are near the bus ceiling, so the *link* is the limit. The second is a
quarter of the same bus, so the *drive* is.

Ceilings are realistic rather than advertised — 8b/10b coding costs USB 3.0 a fifth of
its headline number before framing, so "5 Gbit/s" is treated as ~450 MB/s. Quoting the
advertised rate makes every device look broken.

Comparisons stay inside the right family. A card is measured against cards, a drive
against drives, an internal SSD against internal drives. Getting this wrong is how an
early build reported that my internal SSD was running at "52% of an SD card".

## Cards

A USB card reader never reports the card's UHS class — it presents as generic mass
storage. But a transfer that plateaus at 86 MB/s on a link good for 625 MB/s has told
you what the card is, so the speed class is inferred from measurement. Capacity class
is exact: the SD spec draws SDHC/SDXC strictly by size.

Whether the medium is removable comes from IOKit's `Removable` property, not the
product name, so a portable hard disk in the same throughput band never gets advice
about buying a faster card.

## Transfer sessions

Finished copies are logged with a verdict — what limited it, and what would help.
The one that made this worth building:

> 6.13 GB written to this card while reading 30.2 GB from it. Spotlight indexing the
> volume, and the HFS journal recording an access time for every file read. Writes
> contend with reads on a card, so this slows the import as well as wearing the card.

That import was running at 6.3 MB/s. The same card does 96 MB/s once Spotlight is off.

Attribution uses `proc_pid_rusage` (the source Activity Monitor's Disk tab uses) and
confirms the link to a volume through the process's open file descriptors, rather than
matching on process names — a Finder copy is performed by `DesktopServicesHelper`, not
Finder.

## Notes

No network access. The speed catalogue ships inside the binary and only updates when
you choose the menu item.

Idle cost on a 2015 12" MacBook is about 1% CPU and 40 MB RSS.

MIT.
