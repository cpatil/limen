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
}

/// Attributes disk traffic to the processes causing it.
///
/// Matching on process names would be both incomplete and wrong - a Finder copy is
/// actually performed by DesktopServicesHelper, and any number of unrelated tools
/// move bytes. Instead this reads the kernel's own per-process I/O counters
/// (`proc_pid_rusage`, the same source as Activity Monitor's Disk tab) and confirms
/// the connection to a specific volume through the process's open file descriptors.
///
/// Two limits are worth knowing. Processes owned by other users are unreadable
/// without root - roughly 20 of 230 on a typical machine, mostly system daemons -
/// so their traffic is invisible here rather than misattributed. And `ri_diskio_*`
/// counts a process's disk I/O as a whole, not per device; the open-file check
/// establishes that the process is working on this volume, not that every one of
/// its bytes went there. During a copy both endpoints legitimately show activity.
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
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
            }
        }
        // Non-zero means the process is owned by another user (or has exited).
        guard rc == 0 else { return nil }
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
            var vi = vnode_fdinfowithpath()
            let rc = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi,
                                    Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard rc > 0 else { continue }
            let path = withUnsafeBytes(of: &vi.pvip.vip_path) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if path.hasPrefix(root) { return true }
        }
        return false
    }
}
