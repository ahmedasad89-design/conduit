import Foundation

/// How a drive is physically attached. The raw strings come from
/// `Protocol Characteristics -> Physical Interconnect`; "Apple Fabric" is what
/// the internal Apple Silicon SSD reports.
enum Interconnect: Equatable, Hashable, Sendable {
    case usb
    case thunderbolt
    case appleFabric
    case pciExpress
    case sata
    case sdCard
    case other(String)

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case let s where s.contains("usb"):            self = .usb
        case let s where s.contains("thunderbolt"):    self = .thunderbolt
        case let s where s.contains("apple fabric"):   self = .appleFabric
        case let s where s.contains("pci"):            self = .pciExpress
        case let s where s.contains("sata"):           self = .sata
        case let s where s.contains("secure digital"): self = .sdCard
        default: self = .other(raw ?? "Unknown")
        }
    }

    var label: String {
        switch self {
        case .usb:          return "USB"
        case .thunderbolt:  return "Thunderbolt"
        case .appleFabric:  return "Internal (Apple Fabric)"
        case .pciExpress:   return "PCIe"
        case .sata:         return "SATA"
        case .sdCard:       return "SD Card"
        case .other(let s): return s
        }
    }

    var isUSB: Bool { self == .usb }
}

/// Everything about a device that does not change tick to tick. Resolving this
/// means walking the registry in both directions, so it is computed once when a
/// device appears and refreshed only on mount/unmount.
struct DeviceIdentity: Identifiable, Equatable, Sendable {
    /// The IOBlockStorageDriver's registry entry ID.
    var id: UInt64
    var bsdName: String
    var productName: String
    var vendorName: String
    /// Stable across replugs and BSD-name reuse — the key benchmark history is
    /// filed under. Empty when the device does not publish one.
    var serialNumber: String
    var interconnect: Interconnect
    var location: String
    var capacityBytes: Int64
    var isRemovable: Bool
    var isEjectable: Bool
    var isSolidState: Bool
    var usbLink: USBLink?
    /// BSD names of every media node below this driver, including APFS volumes.
    var childBSDNames: Set<String>
    /// Mounted volumes that live on this physical device.
    var volumes: [VolumeRef]

    var displayName: String {
        let trimmed = productName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !volumes.isEmpty { return volumes[0].name }
        return bsdName
    }

    var isInternal: Bool {
        location.lowercased().contains("internal") || interconnect == .appleFabric
    }

    var symbolName: String {
        if isInternal { return "internaldrive" }
        if interconnect.isUSB { return isRemovable ? "externaldrive.badge.plus" : "externaldrive" }
        return "externaldrive.connected.to.line.below"
    }

    /// The one-line identity under the device name: how it is attached, how
    /// fast, and how big.
    var subtitle: String {
        var parts: [String] = []
        if let link = usbLink {
            parts.append("USB · \(link.lineRateLabel)")
            if link.usesUASP { parts.append("UASP") }
        } else {
            parts.append(interconnect.label)
        }
        if capacityBytes > 0 { parts.append(Format.bytes(capacityBytes)) }
        return parts.joined(separator: " · ")
    }

    /// Compares only what is displayed. The synthesised member-wise `==` would
    /// walk `childBSDNames` — a `Set<String>` of every media node under the
    /// device — on every change check, several times per tick, to answer a
    /// question the UI never asks.
    static func == (a: DeviceIdentity, b: DeviceIdentity) -> Bool {
        a.id == b.id
            && a.bsdName == b.bsdName
            && a.productName == b.productName
            && a.vendorName == b.vendorName
            && a.serialNumber == b.serialNumber
            && a.interconnect == b.interconnect
            && a.location == b.location
            && a.capacityBytes == b.capacityBytes
            && a.isRemovable == b.isRemovable
            && a.usbLink == b.usbLink
            && a.volumes == b.volumes
    }
}

struct VolumeRef: Identifiable, Equatable, Hashable, Sendable {
    var id: String { mountPath }
    var name: String
    var mountPath: String
    var bsdName: String
    var isBootVolume: Bool
    var totalBytes: Int64
    var freeBytes: Int64
    var isWritable: Bool
}

/// One sampling tick for one device.
struct DeviceSample: Equatable, Sendable {
    var readBytesPerSecond: Double
    var writeBytesPerSecond: Double
    var readOpsPerSecond: Double
    var writeOpsPerSecond: Double
    /// Mean service time per operation over the interval, in microseconds.
    /// Derived from `Total Time`; nil when no operations occurred.
    var readLatencyMicros: Double?
    var writeLatencyMicros: Double?
    var readErrors: Int64
    var writeErrors: Int64
    var retries: Int64
    /// Mean number of requests in flight over the interval.
    ///
    /// `Total Time` sums per-operation service times across requests that
    /// overlap, so it can exceed wall-clock time — 16.6 seconds of accumulated
    /// service time inside a 1.0 second window was measured on this Mac. That
    /// ratio is queue depth, and it is the number that explains a latency
    /// spike. It is emphatically not a utilisation percentage.
    var queueDepth: Double?

    static let zero = DeviceSample(readBytesPerSecond: 0, writeBytesPerSecond: 0,
                                   readOpsPerSecond: 0, writeOpsPerSecond: 0,
                                   readLatencyMicros: nil, writeLatencyMicros: nil,
                                   readErrors: 0, writeErrors: 0, retries: 0,
                                   queueDepth: nil)

    var totalBytesPerSecond: Double { readBytesPerSecond + writeBytesPerSecond }
    var isActive: Bool { totalBytesPerSecond > 64 * 1024 }
}

/// A point on the rolling graph.
struct GraphPoint: Identifiable, Equatable, Sendable {
    let id: UInt64
    let t: Double          // seconds since the device started being watched
    let read: Double       // MB/s
    let write: Double      // MB/s
}
