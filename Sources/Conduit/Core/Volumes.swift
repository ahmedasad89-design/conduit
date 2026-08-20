import Foundation

/// Mounted-filesystem snapshot straight from `getmntinfo(2)`.
///
/// The BSD device name is the join key between a mounted volume and the
/// IOBlockStorageDriver that carries its statistics.
enum Volumes {

    struct Mount: Sendable {
        var bsdName: String     // "disk3s5"
        var mountPath: String   // "/System/Volumes/Data"
        var volumeName: String
        var totalBytes: Int64
        var freeBytes: Int64
        var isWritable: Bool
        var isBootVolume: Bool
    }

    static func current() -> [Mount] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var result: [Mount] = []
        result.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let fs = buffer[i]
            let from = charTuple(fs.f_mntfromname)
            let on = charTuple(fs.f_mntonname)
            guard from.hasPrefix("/dev/") else { continue }   // skip devfs, map, autofs

            let bsd = String(from.dropFirst("/dev/".count))
            let blockSize = Int64(fs.f_bsize)
            // f_bavail, not f_bfree: f_bfree includes blocks reserved for root,
            // which a benchmark file cannot actually use.
            let free = Int64(bitPattern: UInt64(fs.f_bavail)) * blockSize
            let total = Int64(bitPattern: UInt64(fs.f_blocks)) * blockSize
            let readOnly = (fs.f_flags & UInt32(MNT_RDONLY)) != 0
            // `MNT_DONTBROWSE` is what marks a volume as system-managed and
            // hides it from Finder. Anything Finder refuses to show is not
            // something to write a scratch file to.
            let hidden = (fs.f_flags & UInt32(MNT_DONTBROWSE)) != 0

            result.append(Mount(
                bsdName: bsd,
                mountPath: on,
                volumeName: displayName(forMountPath: on),
                totalBytes: total,
                freeBytes: free,
                isWritable: !readOnly,
                isBootVolume: isSystemPath(on) || hidden
            ))
        }
        return result
    }

    /// `/`, `/System/Volumes/*` and the VM store are never legitimate benchmark
    /// targets.
    ///
    /// This is not sufficient on its own: the internal drive's Recovery volume
    /// mounts at `/Volumes/Recovery`, is writable, and passes every check here.
    /// It is caught by the `MNT_DONTBROWSE` test in `current()` instead — a
    /// path blacklist would have to guess every name Apple might use.
    static func isSystemPath(_ path: String) -> Bool {
        path == "/" || path.hasPrefix("/System/Volumes/") || path.hasPrefix("/private/var/vm")
    }

    private static func displayName(forMountPath path: String) -> String {
        if path == "/" { return "Macintosh HD" }
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey]),
           let name = values.volumeName, !name.isEmpty {
            return name
        }
        return url.lastPathComponent
    }

    /// `statfs` exposes its char arrays as fixed-size C tuples; this rebinds one
    /// to a `CChar` buffer so it can be read as a String.
    private static func charTuple<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
