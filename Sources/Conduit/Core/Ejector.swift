import Foundation
import DiskArbitration

/// Carries one eject attempt's result back from DiskArbitration's C callbacks.
///
/// Same rule as `DiskWatcher`: the callbacks are `@convention(c)` and run on a
/// dispatch queue, so the context pointer must address something genuinely
/// Sendable. A continuation qualifies; the ejector itself would not.
private final class EjectRequest: Sendable {
    let finish: @Sendable (String?) -> Void
    init(_ finish: @escaping @Sendable (String?) -> Void) { self.finish = finish }
}

/// Unmounts and ejects a drive.
///
/// A list of USB drives without an eject button sends the user to Finder, which
/// is the one thing this app exists to save them from.
@MainActor
final class Ejector {

    private var session: DASession?

    private func makeSession() -> DASession? {
        if let session { return session }
        guard let created = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(created, DispatchQueue.main)
        session = created
        return created
    }

    /// Unmounts each mounted volume, then ejects the media.
    ///
    /// - Parameters:
    ///   - wholeDiskBSD: the physical device, e.g. `disk4`.
    ///   - volumeBSDNames: every mounted volume belonging to it.
    /// - Returns: `nil` on success, or a human-readable reason it failed.
    ///
    /// The volumes have to be unmounted individually rather than by passing
    /// `kDADiskUnmountOptionWhole` on the physical device. That option only
    /// reaches partitions of that same device, and an APFS volume does not live
    /// there — the container is a *synthesized* device (`disk4` carries the
    /// store, but the mounted volume is `disk5s1`). Unmounting the whole
    /// physical disk therefore silently misses every APFS volume on it, which
    /// is most modern drives.
    func eject(wholeDiskBSD: String, volumeBSDNames: [String]) async -> String? {
        guard let session = makeSession() else {
            return "Could not talk to the disk arbitration service."
        }

        for volume in volumeBSDNames {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume) else {
                continue    // already gone; nothing to unmount
            }
            if let failure = await withCheckedContinuation({
                (continuation: CheckedContinuation<String?, Never>) in
                let request = EjectRequest { continuation.resume(returning: $0) }
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                              conduitUnmountDone, Unmanaged.passRetained(request).toOpaque())
            }) {
                return failure
            }
        }

        guard let whole = DADiskCreateFromBSDName(kCFAllocatorDefault, session, wholeDiskBSD) else {
            // Everything is unmounted and the device is gone. Nothing to report.
            return nil
        }
        return await withCheckedContinuation { continuation in
            let request = EjectRequest { continuation.resume(returning: $0) }
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault),
                        conduitEjectDone, Unmanaged.passRetained(request).toOpaque())
        }
    }
}

// MARK: - C callbacks
//
// File scope, for the reason spelled out in DiskWatcher: a closure written
// inside a `@MainActor` type inherits that isolation and traps when called on
// DiskArbitration's queue.
//
// The context is passed retained and consumed here — each callback fires
// exactly once, so this is a hand-off rather than a leak.

/// Turns a DiskArbitration status into something a person can act on.
///
/// The low byte of the status is the `kDAReturn` code; the rest is the error
/// domain. Surfacing the raw number — "status -119930868" — tells the user
/// nothing, and these are the cases that actually occur.
private func describe(_ status: DAReturn) -> String? {
    switch Int(status) & 0xFF {
    case 0x02: return "Something is still using it. Close any open files and try again."
    case 0x03: return "That drive is no longer attached."
    case 0x04: return "Another program has exclusive access to it."
    case 0x06: return "That drive is no longer attached."
    case 0x07: return "It is not mounted."
    case 0x08, 0x09: return "macOS did not permit it."
    case 0x0A: return "The drive is not ready. Try again in a moment."
    case 0x0C: return "This volume does not support being ejected."
    default: return nil
    }
}

private func completion(_ dissenter: DADissenter?,
                        _ context: UnsafeMutableRawPointer?,
                        fallback: String) {
    guard let context else { return }
    let request = Unmanaged<EjectRequest>.fromOpaque(context).takeRetainedValue()

    guard let dissenter else {
        request.finish(nil)
        return
    }
    // The dissenter's own string is best when there is one — it usually names
    // the application still holding a file open. Otherwise decode the status.
    let status = DADissenterGetStatus(dissenter)
    if let reason = DADissenterGetStatusString(dissenter) as String?, !reason.isEmpty {
        request.finish(reason)
    } else if let reason = describe(status) {
        request.finish("\(fallback). \(reason)")
    } else {
        request.finish("\(fallback).")
    }
}

private let conduitUnmountDone: DADiskUnmountCallback = { _, dissenter, context in
    completion(dissenter, context, fallback: "A volume on this drive could not be unmounted")
}

private let conduitEjectDone: DADiskEjectCallback = { _, dissenter, context in
    completion(dissenter, context, fallback: "The drive could not be ejected")
}
