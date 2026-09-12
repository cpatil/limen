import Cocoa

// Renders the hover card offscreen, in both appearances, for a handful of rows that
// between them exercise the layouts that have broken before.
//
// The card is drawn by hand rather than laid out by AppKit, so its height is computed
// in one place and its content painted in another. When those two disagree the panel
// clips what it draws, and no assertion about a string catches it - you have to look.
// The assertions in Tests/ say the text is right; this says the page is.
//
// Run it with tools/render-card.sh, which compiles it against Sources/.

_ = NSApplication.shared

/// Renders one row in one appearance.
///
/// Two things have to be told which appearance this is. Palette has no running
/// application to ask, and AppKit's own dynamic colours - controlBackgroundColor,
/// labelColor - resolve against the *view's* effectiveAppearance, which for a view
/// with no window comes from NSApp, i.e. from whatever this Mac is set to. Miss the
/// second and both passes render identically, which looks like a working check and
/// is not one.
func render(_ row: Row, light: Bool, to path: String) {
    Palette.forcedAppearance = light
    let view = MagnifierView(frame: NSRect(x: 0, y: 0,
                                           width: MagnifierView.width, height: 400))
    view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    view.row = row
    // Its own fitting height, so anything that overflows shows up as a clipped panel
    // rather than being hidden by a generous fixed size.
    view.frame = NSRect(x: 0, y: 0, width: MagnifierView.width, height: view.fittingHeight)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("  \(path)  \(Int(view.frame.width))x\(Int(view.frame.height))")
}

// ---- the fixtures ----------------------------------------------------------
// A multi-volume drive is here because the volumes used to sit inside the identity
// line, where "media · APFS" read as a fourth volume called APFS.

func drive() -> Row {
    var r = Row(id: "usb:9", title: "My Passport",
                subtitle: "Western Digital · 1058:2621 · nam DDLJ, necromancer, media",
                badge: "")
    r.vendor = "Western Digital"
    r.deviceID = "1058:2621"
    r.volumes = ["nam DDLJ", "necromancer", "media"]
    r.fsType = "apfs"
    r.capacityBytes = 4_000_751_529_984
    r.usedBytes = 2_459_539_628_032
    r.removable = true
    r.isPhysical = true
    r.linkBits = 10_000_000_000
    r.deviceNode = "/dev/disk3"
    r.volumeID = "DE61964A-B31F-4E52-8DEB-41D0FC26FD12"
    r.blockSize = 4096
    return r
}

func singleVolume() -> Row {
    var r = drive()
    r.title = "Elements"
    r.volumes = ["media"]
    return r
}

/// A card, whose panel is about the card rather than the reader holding it.
func card() -> Row {
    var r = drive()
    r.title = "USB3.0 Card Reader"
    r.volumes = ["sd-19"]
    r.mediumClass = "SDXC 256 GB"
    r.fsType = "exfat"
    r.capacityBytes = 256_000_000_000
    r.usedBytes = 141_000_000_000
    r.blockSize = 131_072
    r.linkBits = 5_000_000_000
    r.deviceNode = "/dev/disk5s1"
    return r
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/cards"
try? FileManager.default.createDirectory(atPath: out,
                                         withIntermediateDirectories: true)

for (name, row) in [("drive", drive()), ("single", singleVolume()), ("card", card())] {
    for (suffix, light) in [("light", true), ("dark", false)] {
        render(row, light: light, to: "\(out)/\(name)-\(suffix).png")
    }
}
