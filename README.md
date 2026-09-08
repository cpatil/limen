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
