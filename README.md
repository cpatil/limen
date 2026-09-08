# Limen

A native macOS app showing live **network** and **USB** data rates.

Built with AppKit (not SwiftUI) and a macOS 10.14 deployment target, as a universal
`x86_64 + arm64` binary, so it runs on everything from a 2015 12" MacBook through
current Apple Silicon. No Xcode required — it builds with Command Line Tools alone.

## Build and run

```bash
./build.sh                 # produces build/Limen.app
open build/Limen.app
```

## Deploy to another Mac over SSH

```bash
./deploy.sh <ssh-host>     # build, install to /Applications, launch
```

Takes any host reachable over SSH. It installs to `/Applications` (group-writable by admin
users, so no password prompt) and falls back to `~/Applications` when that is not writable.

## What it measures

**Network tab** — per-interface download/upload rates, cumulative totals, link speed, and a
150-sample history graph. Counters come from `sysctl(NET_RT_IFLIST2)` / `if_data64`, which is
64-bit; the simpler `getifaddrs` path exposes only 32-bit counters that wrap every 4 GB.

The headline total counts **hardware interfaces only**. A VPN tunnel (`utun*`), AWDL, or a
bridge carries traffic that is *also* counted on the physical interface it rides over, so
summing every interface reports roughly double the real rate. SystemConfiguration only names
real hardware, which makes it a reliable test for this.

**USB tab** — connected devices with vendor, product ID, and negotiated link speed, plus real
throughput where macOS actually keeps byte counters:

| Device class | Throughput source |
|---|---|
| Storage | `IOBlockStorageDriver` → `Statistics` → `Bytes (Read)` / `Bytes (Write)` |
| Network adapters | the device's BSD interface counters |
| Everything else | none — link speed only, labelled as such in the row |

That last row is the honest limitation: macOS exposes no general per-USB-device byte counters,
so a keyboard, camera, or audio interface reports its negotiated speed and nothing more. Those
rows say `no byte counters for this device class` rather than drawing a flat line that would
look like an idle device.

Throughput is attributed to the device that actually owns it: the registry walk stops at nested
USB devices, so a hub does not absorb the counters of a drive plugged into it.

## Reading the speed, not just the number

A bare "111 MB/s" says little. Each row also shows what the rate is comparable to,
and how much of the link's realistic ceiling it is using:

| Rate | Link | Shown as |
|---|---|---|
| 35 MB/s flash drive | USB 2.0 | 87.5% of link · ≈ USB 2.0 |
| 111 MB/s hard disk | USB 3.0 | 24.7% of link · ≈ Gigabit Ethernet |
| 420 MB/s SSD | USB 3.0 | 93.3% of link · ≈ USB 3.0 |
| 2.6 GB/s NVMe | Thunderbolt | 94.5% of link · ≈ Thunderbolt 3/4 |

The first and third are near their bus ceiling — the *link* is the limit. The second
is a quarter of the same bus, so the *drive* is. The bar turns orange past 85%, and a
tick marks the session peak so a link that briefly maxed out still shows it.

Ceilings are realistic, not advertised. 8b/10b line coding costs USB 3.0 a fifth of
its headline number before any protocol framing, so its "5 Gbit/s" is treated as
~450 MB/s. Quoting the advertised rate makes every device look broken.

The percentage is suppressed when the reported link rate is not credible — macOS
reports `ifi_baudrate` for Wi-Fi as whatever PHY rate it last latched onto, often far
below real throughput, which produced readings like "270% of link". Where the
denominator cannot be trusted the row shows the session peak instead.

## One pane, two measurements

Network and USB appear together, but as **separate readouts** rather than one total.
Copying a card to an SMB share is both at once, and the useful thing is watching the
two move against each other — a combined figure would hide exactly that. The list
below groups rows under each heading; `All / Network / USB` filters the list without
changing the summary.

## Who is actually moving the data

Rows for USB storage name the processes responsible:

```
Elements 2621   down 89.9 MB/s  21% link
  mounted at: /Volumes/nam DDLJ, /Volumes/necromancer, /Volumes/media
  processes:  dd (pid 58384) 89.9 MB/s
```

Matching on process names would be both incomplete and misleading — a Finder copy is
performed by `DesktopServicesHelper`, not Finder. Instead this reads the kernel's own
per-process I/O counters (`proc_pid_rusage`, the same source as Activity Monitor's
Disk tab) and confirms the link to a specific volume through the process's open file
descriptors (`PROC_PIDFDVNODEPATHINFO`) — evidence the kernel vouches for. Descriptor
enumeration is only done for processes already moving meaningful traffic, since it is
the expensive half.

Two limits, stated rather than hidden. Processes owned by other users are unreadable
without root — roughly 20 of 230 on a typical machine, mostly system daemons — so
their traffic is absent rather than misattributed. And `ri_diskio_*` counts a
process's disk I/O as a whole, not per device; the open-file check establishes that a
process is working on this volume, not that every byte went there.

## Quiet advice about removable media

When the measurements support it, a device gets one short suggestion — a card
plateauing near 90 MB/s on a link good for 450 MB/s has told you it is UHS-I, so it
says so and notes what UHS-II would buy.

Whether the medium is removable comes from IOKit's `Removable` property on `IOMedia`,
not from the product name. That distinction matters: a portable hard disk sits in the
same throughput band as a UHS-I card for entirely different reasons, and advising
someone to buy a faster *card* for their spinning disk would be nonsense. It gets
"typical of a portable hard disk — an SSD would be several times faster" instead.

## Verified against real hardware

On a 2015 12" MacBook (MacBook8,1, Core M-5Y71, macOS 11.7.11) with a USB 3.0 drive attached,
a sustained read reported **74.1 MB/s** on the drive's row while the upstream USB 3.1 hub
correctly reported no counters of its own. Idle cost is ~1% CPU and ~40 MB RSS.

## Layout

| File | Role |
|---|---|
| `Sources/NetSampler.swift` | 64-bit interface counters, friendly names, classification |
| `Sources/USBSampler.swift` | IOKit device enumeration and throughput attribution |
| `Sources/Monitor.swift` | sampling timer, counter deltas, rate history |
| `Sources/Charts.swift` | chart and text drawing primitives |
| `Sources/ListView.swift` | custom-drawn device/interface list |
| `Sources/RootView.swift` | window layout, summary panel, app delegate |
| `Sources/Format.swift` | byte/bit rate formatting |
