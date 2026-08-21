import Foundation
import IOKit
import IOKit.storage

struct DeviceReading: Equatable, Sendable {
    var identity: DeviceIdentity
    var sample: DeviceSample
    /// Sticky version of `sample.isActive`, for anything that animates.
    ///
    /// Raw activity flaps: a drive being indexed, or any bursty workload, goes
    /// active/idle/active on consecutive ticks. Driving a transition or a
    /// symbol effect straight off that restarts an animation twice a second,
    /// and over a vibrant surface the compositor then re-blurs continuously —
    /// measured at over 50% of a core on a 2 TB drive mid-Spotlight-index.
    /// The store sets this with hysteresis so the visual state settles.
    var isBusy: Bool = false
}

/// Reads `IOBlockStorageDriver`'s `Statistics` dictionary on a fixed interval and
/// turns the monotonically-increasing counters into rates.
///
/// The counters are cumulative since the driver attached, so throughput is a
/// delta over elapsed time. Three things make that fragile and are handled
/// explicitly below: a device can be unplugged and replugged (counters restart
/// from zero), the tick can fire late under load (dividing by the nominal
/// interval instead of the measured one inflates every number), and the wall
/// clock can be slewed (so the monotonic clock is used instead).
///
/// An actor rather than a class-plus-queue: the loop's timing does not need to
/// be precise because every rate divides by *measured* elapsed nanoseconds, so
/// `Task.sleep` drift is harmless, and this keeps the whole type Sendable
/// without a single unchecked escape hatch.
actor ThroughputSampler {

    /// 4 Hz while data is moving. Fast enough that a flash drive's write stalls
    /// are visible as stalls; slow enough that the registry walk stays near
    /// 0.2% of a core.
    ///
    /// Deliberately not the 8 Hz the plan suggested: 4 Hz is the rate whose
    /// accuracy was checked against `iostat` and `dd` to within about 1%, and
    /// the fine structure 8 Hz would add — cache cliffs, stall sawtooths — is
    /// already captured by the benchmark's own 10 Hz curve. Doubling the cost
    /// of the most expensive state to duplicate that would be a bad trade.
    static let activeInterval: Duration = .milliseconds(250)

    /// 1 Hz when nothing has moved for a while. Nobody is reading a number
    /// that has been zero for ten seconds.
    static let idleInterval: Duration = .milliseconds(1000)

    /// How many consecutive quiet ticks before dropping to the slow rate.
    /// Two seconds, so a pause between files in a copy does not cause the
    /// meter to visibly downshift and then snap back.
    private static let quietTicksBeforeSlowing = 8

    /// The media subtree only changes on mount, unmount or repartition, and
    /// DiskArbitration reports all three. This is the safety net for anything
    /// it misses — every fourth tick, about once a second.
    private static let topologyRefreshEveryNTicks = 4

    /// Latest readings. `bufferingNewest(1)` on purpose: if the UI ever falls
    /// behind, the right recovery is to show the current state, never to work
    /// through a backlog of stale samples.
    nonisolated let readings: AsyncStream<[DeviceReading]>
    private let continuation: AsyncStream<[DeviceReading]>.Continuation

    private var previous: [UInt64: RawCountersSnapshot] = [:]
    private var identities: [UInt64: DeviceIdentity] = [:]
    private var tickCount = 0
    private var forceTopologyRefresh = true
    private var loop: Task<Void, Never>?
    private var quietTicks = 0
    private var adaptive = true

    /// The rate the next sleep will use. Exposed for tests, which cannot
    /// observe timing directly.
    var currentInterval: Duration {
        guard adaptive, quietTicks >= Self.quietTicksBeforeSlowing else { return Self.activeInterval }
        return Self.idleInterval
    }

    init() {
        let (stream, continuation) = AsyncStream<[DeviceReading]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.readings = stream
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: await self.currentInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Called when DiskArbitration reports a mount or unmount, so the volume
    /// list is re-read on the very next tick rather than up to a second later.
    func invalidateTopology() {
        forceTopologyRefresh = true
        // A drive appearing is exactly when the meter should be responsive.
        quietTicks = 0
    }

    func setAdaptive(_ enabled: Bool) {
        adaptive = enabled
        if !enabled { quietTicks = 0 }
    }

    // MARK: - Sampling

    private func tick() {
        tickCount += 1
        let refreshTopology = forceTopologyRefresh
            || tickCount % Self.topologyRefreshEveryNTicks == 0
        forceTopologyRefresh = false

        // Only read the mount table when something could have changed.
        let mounts = refreshTopology ? Volumes.current() : []
        let now = monotonicNanos()

        var batch: [DeviceReading] = []
        var alive = Set<UInt64>()

        IOReg.forEachMatching("IOBlockStorageDriver") { driver in
            let id = IOReg.entryID(driver)
            alive.insert(id)

            guard let stats = IOReg.dict(driver, kIOBlockStorageDriverStatisticsKey) else { return }
            let counters = Self.counters(from: stats, at: now)

            let identity: DeviceIdentity
            if let cached = identities[id] {
                if refreshTopology {
                    var refreshed = cached
                    refreshed.childBSDNames = Self.descendantBSDNames(of: driver)
                    refreshed.volumes = Self.volumes(for: refreshed.childBSDNames, in: mounts)
                    identity = refreshed
                    identities[id] = refreshed
                } else {
                    identity = cached
                }
            } else {
                // A device seen for the first time always needs the mount
                // table, even on a tick that was not a refresh tick.
                identity = Self.buildIdentity(driver: driver, id: id,
                                              mounts: refreshTopology ? mounts : Volumes.current())
                identities[id] = identity
            }

            let sample = Self.rate(from: previous[id], to: counters)
            previous[id] = counters
            batch.append(DeviceReading(identity: identity, sample: sample))
        }

        // Drop anything that went away, otherwise a replugged drive would be
        // diffed against counters from its previous life.
        previous = previous.filter { alive.contains($0.key) }
        identities = identities.filter { alive.contains($0.key) }

        // Only real traffic on a drive this app is about counts as activity.
        // Including the internal SSD meant its constant background I/O reset
        // the counter on nearly every tick, so the slow rate never engaged.
        if batch.contains(where: { $0.sample.isActive && !$0.identity.isInternal }) {
            quietTicks = 0
        } else {
            quietTicks += 1
        }

        continuation.yield(batch)
    }

    private static func counters(from stats: [String: Any], at timestamp: UInt64) -> RawCountersSnapshot {
        func value(_ key: String) -> Int64 { (stats[key] as? NSNumber)?.int64Value ?? 0 }
        return RawCountersSnapshot(
            bytesRead:      value(kIOBlockStorageDriverStatisticsBytesReadKey),
            bytesWritten:   value(kIOBlockStorageDriverStatisticsBytesWrittenKey),
            opsRead:        value(kIOBlockStorageDriverStatisticsReadsKey),
            opsWritten:     value(kIOBlockStorageDriverStatisticsWritesKey),
            totalTimeRead:  value(kIOBlockStorageDriverStatisticsTotalReadTimeKey),
            totalTimeWrite: value(kIOBlockStorageDriverStatisticsTotalWriteTimeKey),
            errorsRead:     value(kIOBlockStorageDriverStatisticsReadErrorsKey),
            errorsWrite:    value(kIOBlockStorageDriverStatisticsWriteErrorsKey),
            retriesRead:    value(kIOBlockStorageDriverStatisticsReadRetriesKey),
            retriesWrite:   value(kIOBlockStorageDriverStatisticsWriteRetriesKey),
            timestamp:      timestamp
        )
    }

    /// Not private: the rate maths is the part most likely to be broken
    /// silently by a refactor, and the replug case cannot be triggered on
    /// demand against real hardware, so tests drive this directly.
    static func rate(from old: RawCountersSnapshot?, to new: RawCountersSnapshot) -> DeviceSample {
        guard let old else { return .zero }

        let elapsedNanos = new.timestamp &- old.timestamp
        guard elapsedNanos > 0 else { return .zero }
        let seconds = Double(elapsedNanos) / 1_000_000_000

        // A negative delta means the counters restarted — a replug, or the
        // driver re-attaching. Report zero for this tick rather than a nonsense
        // spike; the next tick has a clean baseline.
        func delta(_ a: Int64, _ b: Int64) -> Int64 { b >= a ? b - a : 0 }

        let dReadBytes = delta(old.bytesRead, new.bytesRead)
        let dWriteBytes = delta(old.bytesWritten, new.bytesWritten)
        let dReadOps = delta(old.opsRead, new.opsRead)
        let dWriteOps = delta(old.opsWritten, new.opsWritten)
        let dReadTime = delta(old.totalTimeRead, new.totalTimeRead)
        let dWriteTime = delta(old.totalTimeWrite, new.totalTimeWrite)

        // `Total Time` is nanoseconds of accumulated service time. Divided by
        // the operations in the same window it gives mean latency per op. The
        // separate `Latency Time` counters read zero on Apple's NVMe driver and
        // on USB mass storage, so they are deliberately unused — showing a
        // permanent 0 µs would be worse than showing nothing.
        let readLatency = dReadOps > 0 ? Double(dReadTime) / Double(dReadOps) / 1000 : nil
        let writeLatency = dWriteOps > 0 ? Double(dWriteTime) / Double(dWriteOps) / 1000 : nil

        return DeviceSample(
            readBytesPerSecond: Double(dReadBytes) / seconds,
            writeBytesPerSecond: Double(dWriteBytes) / seconds,
            readOpsPerSecond: Double(dReadOps) / seconds,
            writeOpsPerSecond: Double(dWriteOps) / seconds,
            readLatencyMicros: readLatency,
            writeLatencyMicros: writeLatency,
            readErrors: new.errorsRead,
            writeErrors: new.errorsWrite,
            retries: new.retriesRead + new.retriesWrite,
            queueDepth: (dReadOps + dWriteOps) > 0
                ? Double(dReadTime + dWriteTime) / Double(elapsedNanos)
                : nil
        )
    }

    // MARK: - Identity

    private static func buildIdentity(driver: io_service_t,
                                      id: UInt64,
                                      mounts: [Volumes.Mount]) -> DeviceIdentity {
        // Characteristics live on the block-storage device, which is the
        // driver's provider (its parent in the IOService plane).
        var protocolCharacteristics: [String: Any] = [:]
        var deviceCharacteristics: [String: Any] = [:]

        // USB ancestry: the first IOUSBHostDevice above the driver is the drive
        // itself; every further one is a hub sharing bandwidth upstream.
        var usbDevices: [io_registry_entry_t] = []
        var sawUASP = false

        IOReg.walkParents(from: driver) { parent in
            if protocolCharacteristics.isEmpty,
               let pc = IOReg.dict(parent, kIOPropertyProtocolCharacteristicsKey) {
                protocolCharacteristics = pc
            }
            if deviceCharacteristics.isEmpty,
               let dc = IOReg.dict(parent, kIOPropertyDeviceCharacteristicsKey) {
                deviceCharacteristics = dc
            }
            let cls = IOReg.className(parent)
            if cls.contains("UAS") || cls.contains("AttachedSCSI") { sawUASP = true }
            if cls == "IOUSBHostDevice" {
                IOObjectRetain(parent)
                usbDevices.append(parent)
            }
            return true
        }
        defer { usbDevices.forEach { IOObjectRelease($0) } }

        let interconnectRaw = protocolCharacteristics[kIOPropertyPhysicalInterconnectTypeKey] as? String
        let location = protocolCharacteristics[kIOPropertyPhysicalInterconnectLocationKey] as? String ?? "Unknown"

        var link: USBLink?
        if let drive = usbDevices.first {
            func negotiated(_ device: io_registry_entry_t) -> Int? {
                USBLink.bitsPerSecond(linkSpeed: IOReg.int(device, "UsbLinkSpeed"),
                                      usbSpeed: IOReg.int(device, "USBSpeed"),
                                      deviceSpeed: IOReg.int(device, "Device Speed"))
            }
            // The slowest hop wins. A 10 Gb/s drive plugged into a 5 Gb/s hub is
            // a 5 Gb/s drive, and its own link property will not say so.
            let hopSpeeds = usbDevices.compactMap(negotiated)
            let hubs = usbDevices.dropFirst().map {
                IOReg.string($0, "USB Product Name") ?? IOReg.entryName($0)
            }
            if let slowest = hopSpeeds.min() {
                let ownSpeed = negotiated(drive)
                link = USBLink.make(bitsPerSecond: slowest,
                                    hubs: Array(hubs),
                                    uasp: sawUASP,
                                    cappedByHub: ownSpeed.map { slowest < $0 } ?? false)
            }
        }

        let childBSD = descendantBSDNames(of: driver)

        // Capacity and removability come from the whole-disk IOMedia node.
        var capacity: Int64 = 0
        var removable = false
        var ejectable = false
        var wholeDiskBSD = ""
        IOReg.walkDescendants(of: driver, maxDepth: 2) { child, _ in
            guard wholeDiskBSD.isEmpty,
                  IOReg.bool(child, "Whole") == true,
                  let bsd = IOReg.string(child, "BSD Name") else { return }
            wholeDiskBSD = bsd
            capacity = IOReg.int(child, "Size") ?? 0
            removable = IOReg.bool(child, "Removable") ?? false
            ejectable = IOReg.bool(child, "Ejectable") ?? false
        }

        return DeviceIdentity(
            id: id,
            bsdName: wholeDiskBSD.isEmpty ? "disk?" : wholeDiskBSD,
            productName: (deviceCharacteristics["Product Name"] as? String) ?? "",
            vendorName: (deviceCharacteristics["Vendor Name"] as? String) ?? "",
            serialNumber: (deviceCharacteristics["Serial Number"] as? String) ?? "",
            interconnect: Interconnect(raw: interconnectRaw),
            location: location,
            capacityBytes: capacity,
            isRemovable: removable,
            isEjectable: ejectable,
            isSolidState: (deviceCharacteristics["Medium Type"] as? String)?
                .lowercased().contains("solid") ?? false,
            usbLink: link,
            childBSDNames: childBSD,
            volumes: volumes(for: childBSD, in: mounts)
        )
    }

    /// Collects every BSD name below the driver. This deliberately walks the
    /// whole subtree rather than just the partitions: an APFS volume's media
    /// node (`disk3s5`) hangs several levels below the physical media
    /// (`disk0`), and that volume is what appears in the mount table.
    private static func descendantBSDNames(of driver: io_service_t) -> Set<String> {
        var names = Set<String>()
        IOReg.walkDescendants(of: driver) { child, _ in
            if let bsd = IOReg.string(child, "BSD Name") { names.insert(bsd) }
        }
        return names
    }

    private static func volumes(for bsdNames: Set<String>,
                                in mounts: [Volumes.Mount]) -> [VolumeRef] {
        mounts
            .filter { bsdNames.contains($0.bsdName) }
            .map {
                VolumeRef(name: $0.volumeName,
                          mountPath: $0.mountPath,
                          bsdName: $0.bsdName,
                          isBootVolume: $0.isBootVolume,
                          totalBytes: $0.totalBytes,
                          freeBytes: $0.freeBytes,
                          isWritable: $0.isWritable)
            }
            .sorted { $0.mountPath < $1.mountPath }
    }
}

/// One sample of `IOBlockStorageDriver`'s raw counters.
///
/// The rate maths over these encodes rules that were derived empirically —
/// nanosecond units, reset-on-replug, measured-not-nominal elapsed time — and
/// none are obvious from reading the code. Keeping this type non-private is
/// what lets tests pin them.
struct RawCountersSnapshot: Sendable {
    var bytesRead: Int64 = 0
    var bytesWritten: Int64 = 0
    var opsRead: Int64 = 0
    var opsWritten: Int64 = 0
    var totalTimeRead: Int64 = 0
    var totalTimeWrite: Int64 = 0
    var errorsRead: Int64 = 0
    var errorsWrite: Int64 = 0
    var retriesRead: Int64 = 0
    var retriesWrite: Int64 = 0
    var timestamp: UInt64 = 0
}
