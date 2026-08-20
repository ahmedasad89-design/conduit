import Foundation

/// The negotiated USB link a device actually got — not what the drive or the
/// port is *capable* of. A 10 Gb/s SSD in a 480 Mb/s port negotiates 480 Mb/s,
/// and that single fact explains most "why is my drive slow" complaints.
struct USBLink: Equatable, Hashable, Sendable {
    /// Raw negotiated line rate in bits/sec, straight from `UsbLinkSpeed`.
    var bitsPerSecond: Int
    /// e.g. "USB 3.2 Gen 2"
    var generation: String
    /// Line rate after channel encoding overhead (8b/10b or 128b/132b), in MB/s.
    var encodedCeilingMBps: Double
    /// What a good drive actually achieves on this link after protocol overhead.
    var practicalCeilingMBps: Double
    /// USB hubs sitting between this device and the host controller.
    /// Every hub in the chain shares its upstream bandwidth with its siblings.
    var hubsInPath: [String]
    /// UASP (SCSI command queueing) vs legacy Bulk-Only Transport. On a 5 Gb/s
    /// link this is the difference between ~440 MB/s and ~250 MB/s.
    var usesUASP: Bool
    /// True when an upstream hub, not the drive itself, set the ceiling.
    var cappedByHub: Bool

    var isBottleneckedByHub: Bool { !hubsInPath.isEmpty }

    /// Resolution is three-tier because the three properties disagree in format
    /// and not every device publishes all three.
    ///
    /// Verified on this machine (M3, macOS 26):
    ///   USB2.0 hub  → UsbLinkSpeed 480000000,   USBSpeed 3, Device Speed 2
    ///   USB3.2 hub  → UsbLinkSpeed 10000000000, USBSpeed 5, Device Speed 4
    ///   LAN adapter → UsbLinkSpeed 5000000000,  USBSpeed 4, Device Speed 3
    ///
    /// `USBSpeed` follows `tIOUSBHostConnectionSpeed` (Full=1, Low=2, High=3,
    /// Super=4, SuperPlus=5, SuperPlusBy2=6) while `Device Speed` follows the
    /// legacy IOUSBFamily enum (Low=0, Full=1, High=2, Super=3, SuperPlus=4).
    /// Reading one with the other's table is the classic way to report a wrong
    /// link speed, so `UsbLinkSpeed` — an unambiguous bits/sec integer — wins
    /// whenever it is present.
    static func bitsPerSecond(linkSpeed: Int64?, usbSpeed: Int64?, deviceSpeed: Int64?) -> Int? {
        if let raw = linkSpeed, raw > 0 { return Int(raw) }

        if let s = usbSpeed {
            switch s {
            case 1: return 12_000_000            // Full
            case 2: return 1_500_000             // Low
            case 3: return 480_000_000           // High
            case 4: return 5_000_000_000         // Super
            case 5: return 10_000_000_000        // SuperPlus
            case 6: return 20_000_000_000        // SuperPlusBy2
            default: break
            }
        }

        if let s = deviceSpeed {
            switch s {
            case 0: return 1_500_000
            case 1: return 12_000_000
            case 2: return 480_000_000
            case 3: return 5_000_000_000
            case 4: return 10_000_000_000
            case 5: return 20_000_000_000
            default: break
            }
        }
        return nil
    }

    /// Encoding overhead is real and generation-specific: USB 3.0/3.1 Gen 1 uses
    /// 8b/10b (20% lost on the wire), Gen 2 and above use 128b/132b (~3% lost).
    /// The practical figures are what a healthy UASP drive sustains in practice.
    static func make(bitsPerSecond bps: Int, hubs: [String], uasp: Bool,
                     cappedByHub: Bool = false) -> USBLink {
        let generation: String
        let encoded: Double
        let practical: Double

        switch bps {
        case ..<2_000_000:
            generation = "USB 1.0 Low-Speed"
            encoded = 1_500_000.0 / 8 / 1_000_000
            practical = encoded * 0.75
        case ..<100_000_000:
            generation = "USB 1.1 Full-Speed"
            encoded = 12_000_000.0 / 8 / 1_000_000
            practical = encoded * 0.75
        case ..<1_000_000_000:
            generation = "USB 2.0 High-Speed"
            encoded = 480.0 / 8                      // 60 MB/s on the wire
            practical = 42                           // BOT framing overhead is brutal here
        case ..<7_000_000_000:
            generation = "USB 3.2 Gen 1 (5 Gb/s)"
            encoded = 5000.0 / 8 * 0.8               // 8b/10b -> 500 MB/s
            practical = uasp ? 440 : 250
        case ..<15_000_000_000:
            generation = "USB 3.2 Gen 2 (10 Gb/s)"
            encoded = 10000.0 / 8 * (128.0 / 132.0)  // ~1212 MB/s
            practical = uasp ? 1000 : 400
        case ..<30_000_000_000:
            generation = "USB 3.2 Gen 2x2 (20 Gb/s)"
            encoded = 20000.0 / 8 * (128.0 / 132.0)
            practical = uasp ? 2000 : 800
        default:
            generation = "USB4 / Thunderbolt"
            encoded = Double(bps) / 8 / 1_000_000 * (128.0 / 132.0)
            // Bulk-only transport is just as crippling at these rates; the
            // faster branches used to ignore the flag the slower ones honour.
            practical = encoded * (uasp ? 0.75 : 0.35)
        }

        return USBLink(bitsPerSecond: bps,
                       generation: generation,
                       encodedCeilingMBps: encoded,
                       practicalCeilingMBps: practical,
                       hubsInPath: hubs,
                       usesUASP: uasp,
                       cappedByHub: cappedByHub)
    }

    var lineRateLabel: String {
        let gbps = Double(bitsPerSecond) / 1_000_000_000
        if gbps >= 1 {
            return gbps == gbps.rounded() ? "\(Int(gbps)) Gb/s" : String(format: "%.1f Gb/s", gbps)
        }
        let mbps = Double(bitsPerSecond) / 1_000_000
        // Integer division turned the 1.5 Mb/s low-speed link into "1 Mb/s".
        return mbps == mbps.rounded()
            ? "\(Int(mbps)) Mb/s"
            : String(format: "%.1f Mb/s", mbps)
    }
}
