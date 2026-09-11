# Notes for the Show HN post

**Write the submission yourself.** HN's guidelines ask that posts not be generated or
AI-edited text, and the point of a Show HN is that you can answer for every claim in
the thread. This file is the verified material to write *from*, not copy to paste.
Check https://news.ycombinator.com/showhn.html for the current Show HN restrictions
before submitting.

Suggested title — describes only what the app unquestionably does:

    Show HN: Bottleneck – per-device storage and network rates for macOS

Let the diagnosis feature earn attention in the body, with its caveats.

## Facts that hold up

Every number below was measured on my own hardware. Anything not on this list
shouldn't go in the post.

**The card import.** One 167-second window: read 474 MB, written 579 MB, average
6.3 MB/s, peak 20.1 MB/s. More written to the card than read from it, while only
importing. Across all six sessions with that card: 30.2 GB read, 6.13 GB written.
Spotlight was indexing the volume; it was HFS+, journalled, mounted without `noatime`.
After disabling indexing the same card's best recorded peak was 96.5 MB/s.

Keep total, average and peak distinct — that's where the review found me contradicting
myself, quoting 71 MB/s in one place and 96 MB/s in another for the same card.

**Wi-Fi.** Reported a 304 Mbit/s link while sustaining 30.2 MB/s, and logged a peak
above its own stated rate. That's why `ifi_baudrate` is not used as a ceiling for
wireless.

**Build.** Universal x86_64 + arm64, `swiftc` and Command Line Tools only, no Xcode,
no dependencies. Reproducible: a clean checkout gives a byte-identical executable.
Tested on macOS 11.7.11 / Intel and macOS 26 / Apple Silicon.

**The bug worth telling.** `proc_pid_rusage`'s third parameter is typed
`rusage_info_t *`, but `rusage_info_t` is itself `void *` — so that's not a level of
indirection. The kernel writes the whole 296-byte struct at the address you pass.
Passing `&someLocal` writes 296 bytes across your stack, returns 0, and hands back
zeros; the crash arrives later in `__stack_chk_fail`. Good material, but it belongs
below the main claims, not above them.

## Say these before anyone asks

Leading with the limits is what makes the rest credible.

- Byte counters are solid. Everything downstream — which component was the
  bottleneck, which process moved which bytes, why a card took writes — is inference.
- Process attribution is an association, not accounting. `proc_pid_rusage` is
  process-wide; the open-descriptor check only proves the process holds a file on that
  volume.
- A plateau near a known ceiling is *consistent with* that medium. The reader, the
  destination, the filesystem and the workload are alternatives it can't rule out.
- The download is unsigned and unnotarised. Source build is the honest primary path.
- The data rows aren't exposed to VoiceOver yet.

## Don't write

"Nothing in macOS shows this" — `iostat -w 1 disk0` does per-disk throughput, and
someone will say so in the first ten minutes. The real difference is names, volumes,
direction split, history, and the hints.

Also avoid "what's actually limiting each one", "has told you what the card is",
"Wi-Fi lies", and "actually". They're punchy and they overclaim. The card-import story
is strong enough flat.

## Shape

1. Two sentences: what annoyed you, what it shows now.
2. The card import, one consistent set of numbers.
3. What's measured vs what's inferred.
4. The limitations above.
5. One paragraph of implementation: IOKit storage counters, routing-socket interface
   counters, AppKit, no network access.
6. Tested OS/hardware, and what feedback you want.

Plain paragraphs — HN comments don't render Markdown headings or tables.
