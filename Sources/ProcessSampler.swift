import Darwin
import Foundation

/// One process's cumulative disk activity.
struct ProcSample {
    var pid: Int32
    var name: String
    var read: UInt64
    var written: UInt64
}

/// A process implicated in traffic on a particular volume, with its current rate.
struct Actor {
    var name: String
    var pid: Int32
    var bytesPerSec: Double
    /// The application this helper works for, when it is a known helper. macOS
    /// parents every GUI helper to launchd, so the process tree cannot tell you that
    /// DesktopServicesHelper is doing a Finder copy - a curated map can.
    var owner: String = ""

    var display: String { owner.isEmpty ? name : "\(name) (\(owner))" }
}

/// Attributes disk traffic to the processes causing it.
///
/// Matching on process names would be both incomplete and wrong - a Finder copy is
/// actually performed by DesktopServicesHelper, and any number of unrelated tools
/// move bytes. Instead this reads the kernel's own per-process I/O counters
/// (`proc_pid_rusage`, the same source as Activity Monitor's Disk tab) and confirms
/// the connection to a specific volume through the process's open file descriptors.
///
/// This is an association signal, not per-volume accounting, and the difference
/// matters. `ri_diskio_*` counts a process's disk I/O as a whole; the open-file check
/// establishes only that the process holds a descriptor on this volume. A process
/// reading heavily from one disk while merely holding a file open on another will
/// have its whole rate shown against both. During a copy both endpoints legitimately
/// show activity.
///
/// Processes owned by other users are unreadable without root - roughly 20 of 230 on
/// a typical machine, mostly system daemons - so their traffic is missing. Missing is
/// not the same as safe: what remains can still be attributed to the wrong volume.
enum ProcessSampler {

    static func sample() -> [Int32: ProcSample] {
        var pids = [Int32](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [:] }
        let count = Int(bytes) / MemoryLayout<Int32>.size

        var out: [Int32: ProcSample] = [:]
        out.reserveCapacity(count)
        for i in 0..<count where pids[i] > 0 {
            let pid = pids[i]
            guard let io = diskIO(pid), io.read + io.written > 0 else { continue }
            out[pid] = ProcSample(pid: pid, name: processName(pid), read: io.read, written: io.written)
        }
        return out
    }

    private static func diskIO(_ pid: Int32) -> (read: UInt64, written: UInt64)? {
        // `proc_pid_rusage`'s third parameter is typed `rusage_info_t *`, but
        // `rusage_info_t` is itself `void *` - so that type name is a historical wart,
        // not a real level of indirection. The kernel writes the whole struct AT the
        // address you hand it. Passing `&someLocal` (a pointer to an 8-byte pointer)
        // makes it write 296 bytes across the stack: silent garbage, then
        // __stack_chk_fail on return. Pass the buffer itself, rebound to the pointer
        // type Swift imported. There is no size argument, so the buffer must be at
        // least as large as the flavour; allocate room to spare.
        let capacity = max(MemoryLayout<rusage_info_v4>.stride * 2, 4096)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity,
                                                  alignment: MemoryLayout<rusage_info_v4>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)

        let slot = raw.bindMemory(to: rusage_info_t?.self,
                                  capacity: capacity / MemoryLayout<rusage_info_t?>.stride)
        guard proc_pid_rusage(pid, RUSAGE_INFO_V4, slot) == 0 else { return nil }
        let info = raw.loadUnaligned(as: rusage_info_v4.self)
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    private static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        let name = String(cString: buf)
        return name.isEmpty ? "pid \(pid)" : name
    }

    /// Mount point for each BSD device name, e.g. "disk5s2" -> "/Volumes/media".
    static func mountPoints() -> [String: String] {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let list = buf else { return [:] }

        var map: [String: String] = [:]
        for i in 0..<Int(count) {
            var entry = list[i]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard from.hasPrefix("/dev/") else { continue }
            map[String(from.dropFirst(5))] = on
        }
        return map
    }

    /// How full a mounted volume is, and which container it belongs to.
    ///
    /// Everything here belongs to the container, not to the volume. `statfs` returns
    /// byte-identical blocks, bfree and bavail for every volume in an APFS container:
    /// four volumes on a 3.6 TB disk each report "3.6 TB, 1.14 TB free", so summing
    /// them claims 14.4 TB of disk and summing their used claims four times the space.
    ///
    /// Per-volume usage is not available this way at all - Finder and `df` get it from
    /// APFS directly. For a per-device bar that does not matter: the container's used
    /// and free are what the device actually holds, which is the question being asked.
    struct VolumeSpace {
        /// The container's size, not this volume's share of it.
        var capacity: UInt64 = 0
        /// What this one volume occupies.
        var used: UInt64 = 0
        /// "disk3" for /dev/disk3s2 - volumes sharing this share their free space.
        var container: String = ""
    }

    static func volumeSpace() -> [String: VolumeSpace] {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let list = buf else { return [:] }

        var map: [String: VolumeSpace] = [:]
        for i in 0..<Int(count) {
            var entry = list[i]
            let on = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard from.hasPrefix("/dev/disk") else { continue }
            let block = UInt64(entry.f_bsize)
            var space = VolumeSpace()
            space.capacity = UInt64(entry.f_blocks) * block
            space.used = UInt64(entry.f_blocks - entry.f_bfree) * block
            space.container = ProcessSampler.container(ofBSDName: String(from.dropFirst(5)))
            map[on] = space
        }
        return map
    }

    /// "disk3s2" -> "disk3". The slice is the volume; the disk is the container.
    static func container(ofBSDName name: String) -> String {
        guard name.hasPrefix("disk") else { return name }
        let rest = name.dropFirst(4)
        let number = rest.prefix { $0.isNumber }
        return number.isEmpty ? name : "disk" + number
    }

    /// Total capacity and used space for a set of mount points, counting each
    /// container's capacity once however many of its volumes are mounted.
    static func combinedSpace(of mounts: [String],
                              in table: [String: VolumeSpace]) -> (capacity: UInt64, used: UInt64)? {
        // Once per container, for used as well as capacity: mounting six volumes of
        // one APFS container must not report six times its size or six times its
        // contents, because every one of them reports the container's figures as its
        // own - statfs returns byte-identical numbers for all six.
        //
        // But "one disk" is not the same thing as "one pool of space". A partitioned
        // HDD carrying two HFS+ volumes has two filesystems that genuinely add up, and
        // keeping only the larger reported half the drive and one partition's
        // contents. What separates the two cases is whether the figures are identical:
        // shared space reports the same numbers, and separate partitions do not.
        //
        // The assumption this rests on: two partitions with exactly equal capacity and
        // exactly equal bytes used would be taken for one. That is a coincidence to
        // the byte, and the alternative - trusting the disk number alone - is wrong
        // every time for a partitioned disk rather than almost never.
        var seen: [String: Set<String>] = [:]
        var capacity: UInt64 = 0
        var used: UInt64 = 0
        for mount in mounts {
            guard let space = table[mount] else { continue }
            let fingerprint = "\(space.capacity)/\(space.used)"
            if seen[space.container]?.contains(fingerprint) == true { continue }
            seen[space.container, default: []].insert(fingerprint)
            capacity += space.capacity
            used += space.used
        }
        guard !seen.isEmpty else { return nil }
        return (capacity, min(used, capacity))
    }

    /// What a mounted volume does to itself while you read from it.
    ///
    /// A card you are only importing from should not be taking writes, and when it is,
    /// these are the reasons: a journalled filesystem mounted without `noatime`
    /// commits an access-time update for every file read, and Spotlight builds its
    /// index onto the volume itself. Both are read from the mount table and the disk
    /// rather than assumed, so the advice can name the actual cause.
    struct VolumeTraits {
        var fsType = ""
        /// The allocation unit: the smallest amount of space a file can occupy.
        ///
        /// Rarely shown anywhere, and on a card it explains more than almost anything
        /// else on screen. This one is formatted with 256 KB clusters, so a thousand
        /// small files occupy at least 256 MB and are copied in a thousand separate
        /// reads - which is exactly what "averaged 19% of its peak" looks like.
        var blockSize: UInt32 = 0
        /// The lock switch, or a filesystem mounted read-only for any other reason.
        var readOnly = false
        /// The device node, for anyone who wants to reach past Finder.
        var device = ""
        /// Journalled and updating access times: reading writes.
        var journalWrites = false
        var spotlight = false
        /// A `.metadata_never_index` marker at the volume root: a positive statement
        /// that Spotlight is not to index this volume. Unlike the presence of an index
        /// directory, which survives indexing being turned off, this one means what it
        /// says.
        var neverIndex = false
    }

    static func volumeTraits() -> [String: VolumeTraits] {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let list = buf else { return [:] }

        var map: [String: VolumeTraits] = [:]
        for i in 0..<Int(count) {
            var entry = list[i]
            let on = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            // Every mount, not just /Volumes. The filesystem is a fact about any
            // device Bottleneck shows, and the boot drive - which is mounted at / and
            // under /System/Volumes - was the one row that could never say what it
            // was formatted as. Same filter, same mistake, as the one that left the
            // internal drive with no capacity gauge.
            let fs = withUnsafeBytes(of: &entry.f_fstypename) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            let journaled = (entry.f_flags & UInt32(MNT_JOURNALED)) != 0
            let noatime = (entry.f_flags & UInt32(MNT_NOATIME)) != 0
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            var traits = VolumeTraits()
            traits.fsType = fs
            traits.blockSize = entry.f_bsize
            traits.readOnly = (entry.f_flags & UInt32(MNT_RDONLY)) != 0
            traits.device = from
            traits.journalWrites = journaled && !noatime
            traits.spotlight = FileManager.default.fileExists(atPath: on + "/.Spotlight-V100")
            traits.neverIndex = FileManager.default.fileExists(atPath: on + "/.metadata_never_index")
            map[on] = traits
        }
        return map
    }

    /// The volume's own identity, which does not depend on what it is plugged into.
    ///
    /// macOS gives every mounted volume a UUID - for exFAT and FAT it derives one from
    /// the volume serial written on the medium itself - so the same card reports the
    /// same identity through any reader. That is what makes "this card, through the
    /// old reader and the new one" a comparison rather than two unrelated histories.
    ///
    /// Names cannot do this job: a freshly formatted card is "Untitled" or "NO NAME",
    /// and two of them would merge into one history.
    static func volumeIdentity(of mount: String) -> String? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        return (try? URL(fileURLWithPath: mount).resourceValues(forKeys: keys))?
            .volumeUUIDString
    }

    /// Whether a mount point is a volume the user sees in Finder.
    ///
    /// "/Volumes/..." is the obvious answer and not the only one: with the sealed
    /// system volume macOS also reports mounts under "/System/Volumes/Data/Volumes",
    /// which is the same place reached through the firmlink. Testing only the short
    /// form meant a card mounted the long way had no volume name, no volume to attach
    /// processes to, and a logged session that said "no volume recorded" while 1.69 GB
    /// came off it.
    static let dataVolumePrefix = "/System/Volumes/Data/Volumes/"

    static func isFinderVolume(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.hasPrefix(dataVolumePrefix)
    }

    /// The same mount as Finder would name it, so two spellings of one volume do not
    /// become two volumes.
    static func finderPath(_ path: String) -> String {
        guard path.hasPrefix(dataVolumePrefix) else { return path }
        return "/Volumes/" + String(path.dropFirst(dataVolumePrefix.count))
    }

    /// Whether `path` lies inside `root`, respecting path boundaries.
    ///
    /// A plain prefix test counted "/Volumes/card-old/f" as being under
    /// "/Volumes/card", which quietly attributed one card's traffic to another.
    static func isUnder(path: String, root: String) -> Bool {
        guard !root.isEmpty else { return false }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == base || path.hasPrefix(base + "/")
    }

    /// True when this process holds an open file anywhere under `root`.
    ///
    /// This is the "who is actually touching this device" check: a descriptor on the
    /// volume is evidence the kernel can vouch for, unlike a name.
    static func hasOpenFile(pid: Int32, under root: String) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size) > 0 else { return false }

        for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            // Same reasoning: an oversized heap buffer rather than a struct on the
            // stack sized by MemoryLayout.size.
            let capacity = max(MemoryLayout<vnode_fdinfowithpath>.stride * 2, 4096)
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: capacity, alignment: MemoryLayout<vnode_fdinfowithpath>.alignment)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)

            let rc = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, raw,
                                    Int32(MemoryLayout<vnode_fdinfowithpath>.stride))
            guard rc > 0 else { continue }
            let info = raw.loadUnaligned(as: vnode_fdinfowithpath.self)
            var pathBytes = info.pvip.vip_path
            let path = withUnsafeBytes(of: &pathBytes) { bytes -> String in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if isUnder(path: path, root: root) { return true }
        }
        return false
    }
}
