import Foundation
import IOKit

/// Thin, leak-free wrappers over the handful of IORegistry calls Conduit needs.
///
/// Every `io_object_t` returned by IOKit carries a retain that the caller owns.
/// The helpers here either release what they take or hand ownership over
/// explicitly, so callers never have to reason about it twice.
enum IOReg {

    // MARK: - Properties

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let cf = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue()
    }

    static func dict(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        property(entry, key) as? [String: Any]
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int64? {
        // IOKit hands numbers back as NSNumber regardless of their kernel width.
        (property(entry, key) as? NSNumber)?.int64Value
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        (property(entry, key) as? NSNumber)?.boolValue ?? (property(entry, key) as? Bool)
    }

    // MARK: - Identity

    static func className(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buf) == KERN_SUCCESS else { return "?" }
        return decode(buf)
    }

    static func entryName(_ entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buf) == KERN_SUCCESS else { return "?" }
        return decode(buf)
    }

    /// IOKit fills fixed-size C buffers. Truncate at the null terminator and
    /// decode explicitly rather than using the deprecated `String(cString:)`.
    private static func decode(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Stable for the lifetime of the service — safe to use as a dictionary key
    /// across sampling ticks, unlike the `io_service_t` port itself.
    static func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    // MARK: - Traversal

    /// Every matching service, already retained; the closure must not release them.
    static func forEachMatching(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(className),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// Walks from `entry` towards the root of the IOService plane.
    /// Return `false` from `body` to stop early.
    static func walkParents(from entry: io_registry_entry_t,
                            limit: Int = 24,
                            _ body: (io_registry_entry_t) -> Bool) {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<limit {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { return }
            let keepGoing = body(parent)
            IOObjectRelease(current)
            current = parent
            if !keepGoing { return }
        }
    }

    /// Depth-first walk of everything below `entry` in the IOService plane.
    static func walkDescendants(of entry: io_registry_entry_t,
                                depth: Int = 0,
                                maxDepth: Int = 12,
                                _ body: (io_registry_entry_t, Int) -> Void) {
        guard depth < maxDepth else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child, depth)
            walkDescendants(of: child, depth: depth + 1, maxDepth: maxDepth, body)
            IOObjectRelease(child)
        }
    }
}

/// `CLOCK_MONOTONIC_RAW` — immune to NTP slew and to the user changing the clock,
/// which a wall-clock timestamp is not. Throughput is a division by elapsed time,
/// so a slewed clock silently corrupts every number the app displays.
@inline(__always)
func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}
