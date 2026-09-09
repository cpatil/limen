# Show HN: Limen – see what your USB and network are actually doing on a Mac

I kept importing photos off SD cards and it kept feeling slower than it should.
Activity Monitor won't show you the throughput of one USB device, and nothing in
macOS will tell you what's capping it, so I wrote something that would.

Limen is a small AppKit app. Live read/write rates for every storage device and
network interface, and — the part I actually wanted — what's limiting each one.

## The first thing it told me was embarrassing

I was copying 65 GB off a card and getting 6.3 MB/s. The same card had sustained
85.8 MB/s an hour earlier. Limen showed the card taking **579 MB of writes while I
read 474 MB off it**.

Spotlight had decided to index the card, and it builds the index onto the card. The
volume was HFS+ with journaling on and no `noatime`, so every file I read also
committed an access-time update. Writes on a UHS-I card are slow and they contend
with reads. Once indexing was off the same card read at 71 MB/s.

I'd never have found that by watching a progress bar. Both numbers were sitting
right there in the kernel's counters; nothing surfaces them.

## What it can and can't see

Storage throughput comes from `IOBlockStorageDriver`'s `Statistics` dictionary,
network from `sysctl(NET_RT_IFLIST2)` and the 64-bit `if_data64` (the easier
`getifaddrs` path gives you 32-bit counters that wrap every 4 GB, which is useless
on anything modern).

macOS keeps no general per-USB-device byte counters, so a keyboard or an audio
interface gets its negotiated link speed and nothing else. Those rows say so instead
of drawing a flat line that looks like an idle device. Processes owned by other users
are unreadable without root, so their I/O is missing rather than misattributed. I'd
rather the tool say "I can't see this" than quietly guess.

## Rates are meaningless without a denominator

"111 MB/s" tells you nothing on its own. Every row compares itself to a catalogue of
real media and buses, and only against its own kind — a card against cards, a drive
against drives, an internal SSD against internal drives. Getting that wrong is how an
early build cheerfully reported that my internal SSD was running at "52% of an SD
card".

A USB card reader never reports the card's UHS class; it presents as generic mass
storage. But a transfer that plateaus at 86 MB/s on a link good for 625 MB/s has told
you what the card is, so the advice is inferred from measurement rather than a
specification nobody exposes. Capacity class is easier: the SD spec draws SDHC/SDXC
strictly by size, so 256 GB is an SDXC and there's nothing to guess.

Wi-Fi lies, incidentally. Mine reported a 304 Mbit/s link while doing 30.2, and I
recorded a peak that exceeded its own claimed ceiling. So `ifi_baudrate` is distrusted
for anything SystemConfiguration says is wireless, and those rows measure against
their own observed best instead of a fictional link rate.

## One bug worth passing on

`proc_pid_rusage`'s third parameter is typed `rusage_info_t *`. But `rusage_info_t`
is itself `void *`, so that's not a level of indirection — the kernel writes the whole
296-byte struct at the address you hand it. Pass `&someLocal` and it writes 296 bytes
across your stack, returns 0, and hands you zeros. The crash arrives later, in
`__stack_chk_fail`, on the way out of a function that looks innocent.

## Details

AppKit, no SwiftUI. Universal x86_64 + arm64 with a 10.14 deployment target, so it
runs on a 2015 12" MacBook as well as current hardware. Builds with `swiftc` and the
Command Line Tools — no Xcode, no package manager, one shell script.

It makes no network connections. The speed catalogue ships in the binary and updates
only when you pick the menu item.

MIT. Source: https://github.com/cpatil/limen
