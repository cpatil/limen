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
    r.deviceNode = "/dev/disk3s2"
    r.volumeID = "49BEB94C-F062-4D52-B20D-B2031E408AD9"
    r.blockSize = 4096
    r.volumeDetails = [
        detail("nam DDLJ", "/dev/disk3s2", "apfs", 4096, false,
               "49BEB94C-F062-4D52-B20D-B2031E408AD9"),
        detail("necromancer", "/dev/disk3s3", "apfs", 4096, false,
               "F077C830-31FF-4105-9F36-0869E0DC11AE"),
        detail("media", "/dev/disk3s4", "apfs", 4096, false,
               "725B5E5A-6209-4EFF-B924-9ED471FE7E13"),
    ]
    return r
}

func detail(_ name: String, _ node: String, _ fs: String, _ block: UInt32,
            _ readOnly: Bool, _ uuid: String) -> Row.VolumeDetail {
    var d = Row.VolumeDetail()
    d.name = name; d.mount = "/Volumes/" + name; d.device = node
    d.fsType = fs; d.blockSize = block; d.readOnly = readOnly; d.uuid = uuid
    return d
}

func singleVolume() -> Row {
    var r = drive()
    r.title = "Elements"
    r.volumes = ["media"]
    r.volumeDetails = [detail("media", "/dev/disk4s2", "apfs", 4096, false,
                              "725B5E5A-6209-4EFF-B924-9ED471FE7E13")]
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
    r.vendor = "Generic"
    r.deviceID = "05e3:0751"
    r.volumeDetails = [detail("sd-19", "/dev/disk5s1", "exfat", 131_072, true,
                              "F1860868-2085-3021-B992-E6D84DE42A69")]
    return r
}

/// A partitioned drive whose volumes disagree: different formats, different
/// allocation units, one of them locked. The old panel described the first of these
/// and put the device's name on the answer.
func mixed() -> Row {
    var r = drive()
    r.title = "Backup HDD"
    r.volumes = ["Archive", "Scratch"]
    r.capacityBytes = 2_000_398_934_016
    r.usedBytes = 1_810_000_000_000
    r.volumeDetails = [
        detail("Archive", "/dev/disk6s1", "exfat", 131_072, true,
               "11111111-2222-3333-4444-555555555555"),
        detail("Scratch", "/dev/disk6s2", "hfs", 4096, false,
               "66666666-7777-8888-9999-000000000000"),
    ]
    return r
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/cards"
try? FileManager.default.createDirectory(atPath: out,
                                         withIntermediateDirectories: true)

for (name, row) in [("drive", drive()), ("single", singleVolume()),
                    ("card", card()), ("mixed", mixed())] {
    for (suffix, light) in [("light", true), ("dark", false)] {
        render(row, light: light, to: "\(out)/\(name)-\(suffix).png")
    }
}
