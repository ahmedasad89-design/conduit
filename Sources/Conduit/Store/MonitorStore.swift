import Foundation
import Observation

/// The offered test sizes, defined once.
///
/// These are decimal, matching every size this app prints. They also have to be
/// the *only* definition: the picker's tags and the store's default were
/// declared separately, drifted (`1 << 30` against a `1_000_000_000` tag), and
/// the segmented control opened with nothing selected while the first run
/// recorded an unlabelled 1.07 GB — which then failed the same-size check and
/// silently orphaned its own comparison baseline.
enum BenchmarkSize: CaseIterable, Identifiable, Sendable {
    case small, standard, large, exhaustive

    var id: Int64 { bytes }

    var bytes: Int64 {
        switch self {
        case .small:      256_000_000
        case .standard:   1_000_000_000
        case .large:      4_000_000_000
        case .exhaustive: 16_000_000_000
        }
    }

    var label: String {
        switch self {
        case .small:      "256 MB"
        case .standard:   "1 GB"
        case .large:      "4 GB"
        case .exhaustive: "16 GB"
        }
    }

    static let `default` = BenchmarkSize.standard
}

/// A volume the speed test is allowed to run on, with the label shown in the
/// picker (its link rate, which is the thing worth knowing when choosing).
struct BenchmarkTarget: Identifiable, Equatable, Sendable {
    var id: String { volume.mountPath }
    var label: String
    var volume: VolumeRef
}

@MainActor
@Observable
final class MonitorStore {

    /// The app owns exactly one store for its whole lifetime.
    ///
    /// This is a singleton rather than an `@State` in the `App` struct because
    /// the macOS 27 SDK turned `@State` into a macro backed by `SwiftUIMacros`,
    /// a plugin that ships with Xcode and not with the Command Line Tools this
    /// project builds against. `@Observable` needs no wrapper for SwiftUI to
    /// track it — reading a property inside `body` is enough.
    static let shared = MonitorStore()

    /// 60 seconds of history at the sampler's 4 Hz.
    private static let historyLength = 240

    // MARK: - Observable state
    //
    // Every published collection is change-gated on assignment. Assigning an
    // identical value still wakes each observing view, and the internal drive
    // produces background I/O continuously, so ungated assignment is what took
    // idle CPU from 0.5% to 6% before this was fixed.

    private(set) var history: [UInt64: [GraphPoint]] = [:]
    private(set) var usbDevices: [DeviceReading] = []
    /// Non-USB but still external: Thunderbolt and USB4 NVMe enclosures report
    /// `PCI-Express`, card readers report `Secure Digital`.
    private(set) var externalDevices: [DeviceReading] = []
    private(set) var internalDevices: [DeviceReading] = []
    private(set) var benchmarkTargets: [BenchmarkTarget] = []

    /// Precomputed so the menu bar only redraws when its text actually changes.
    private(set) var menuBarText: String = ""
    private(set) var usbDeviceCount: Int = 0

    var selectedDeviceID: UInt64?
    /// A passthrough to the preference, not a copy of it.
    ///
    /// This was briefly a mirrored stored property, which meant the sidebar
    /// toggle and the one in Settings each wrote a different variable: flipping
    /// it in Settings appeared to do nothing until the app was relaunched.
    /// Observation still works through the computed accessor, because reading
    /// it touches `Preferences`, which is itself `@Observable`.
    var showInternalDrives: Bool {
        get { Preferences.shared.showInternalDrives }
        set { Preferences.shared.showInternalDrives = newValue }
    }
    /// Set when an eject fails, so the UI can explain why.
    var ejectFailure: String?

    // Benchmark state
    var benchmarkProgress = BenchmarkProgress()
    var benchmarkResults: BenchmarkResults?
    var benchmarkVolume: VolumeRef?
    var benchmarkSizeBytes: Int64 = BenchmarkSize.default.bytes
    var showingSpeedTest = false
    /// The previous run on this same drive, for the comparison line.
    private(set) var previousRun: BenchmarkRecord?

    // MARK: - Private state

    /// Not published: this churns every tick from background system I/O even
    /// when nothing on screen depends on it.
    private var readings: [DeviceReading] = []
    /// History accumulates at the sampler's full 4 Hz so no spike is lost, but
    /// is handed to SwiftUI only on publish ticks.
    private var pendingHistory: [UInt64: [GraphPoint]] = [:]
    private var historyDirty = false

    private let sampler = ThroughputSampler()
    private let watcher = DiskWatcher()
    private let benchmark = BenchmarkRunner()
    private let ejector = Ejector()
    /// Devices already announced, so a notification fires on connect and not
    /// on every tick thereafter.
    private var announced: Set<UInt64> = []
    private var gate = PublishGate(publishEvery: 2, idleTicksBeforeFreeze: historyLength)
    private var pumps: [Task<Void, Never>] = []
    private var sequence: UInt64 = 0
    private var startedAtNanos: UInt64 = 0
    /// Tick each device was last genuinely moving data, for the `isBusy`
    /// hysteresis below.
    private var lastBusyTick: [UInt64: Int] = [:]
    /// Roughly 1.5 seconds at the 4 Hz sample rate. Long enough that a gap
    /// between two bursts does not read as "stopped", short enough that a drive
    /// which really has finished stops looking busy promptly.
    private static let busyLingerTicks = 6

    /// Captured when a run starts: results are filed under the drive's serial,
    /// and the volume alone does not identify the drive.
    private var benchmarkDrive: DeviceIdentity?

    // MARK: - Lifecycle

    func start() {
        startedAtNanos = monotonicNanos()
        // Off the main thread, and off the launch path entirely — see below.
        Task.detached(priority: .utility) { Self.sweepAbandonedScratchFiles() }
        watcher.start()

        // Restarting after a stop() only needs the actor's loop back.
        guard pumps.isEmpty else {
            let sampler = self.sampler
            Task { await sampler.start() }
            return
        }

        let adaptive = Preferences.shared.adaptiveSampling
        pumps.append(Task { [weak self] in
            guard let self else { return }
            await self.sampler.setAdaptive(adaptive)
            await self.sampler.start()
            for await batch in self.sampler.readings {
                self.apply(batch)
            }
        })

        pumps.append(Task { [weak self] in
            guard let self else { return }
            for await _ in self.watcher.changes {
                await self.sampler.invalidateTopology()
            }
        })
    }

    /// Pauses sampling. Deliberately does **not** cancel the pump tasks:
    /// cancelling the task that is iterating the sampler's `AsyncStream` ends
    /// that stream permanently, and a later `start()` would return a store that
    /// silently never receives another reading. Stopping the actor's own loop
    /// is enough, and is reversible.
    func stop() {
        watcher.stop()
        let sampler = self.sampler
        Task { await sampler.stop() }
    }

    /// A benchmark deletes its scratch file on every exit path it controls, but
    /// it cannot clean up after a force-quit or a panic — which could strand up
    /// to 16 GB in a hidden file. Previously the only thing that removed it was
    /// running another test on that same volume.
    ///
    /// `nonisolated`, and always called from a detached task. This enumerates
    /// every mounted volume, and directory enumeration blocks in `open(2)`:
    /// on a parked external hard disk that is seconds, and on an unreachable
    /// network mount it can be much longer. It was originally called
    /// synchronously from `start()`, which runs inside `App.init()` — so the
    /// main thread blocked before SwiftUI had built a single scene, and the app
    /// launched with no window, no menu bar item, and no error. Stranding a
    /// scratch file is a far smaller problem than never starting.
    nonisolated private static func sweepAbandonedScratchFiles() {
        for mount in Volumes.current() where mount.isWritable && !mount.isBootVolume {
            BenchmarkRunner.sweepStaleFiles(on: mount.mountPath)
        }
    }

    // MARK: - Derived views

    /// The internal drive is the only thing hidden by default, and it is the
    /// only bucket that churns constantly — so with the toggle off the ternary
    /// short-circuits, no view reads `internalDevices`, and none becomes
    /// dependent on that churn.
    var visibleDevices: [DeviceReading] {
        showInternalDrives ? usbDevices + externalDevices + internalDevices
                           : usbDevices + externalDevices
    }

    var selected: DeviceReading? {
        let pool = visibleDevices
        guard let id = selectedDeviceID else { return pool.first }
        return pool.first { $0.identity.id == id } ?? pool.first
    }

    func history(for id: UInt64) -> [GraphPoint] { history[id] ?? [] }

    // MARK: - Sampling

    private func apply(_ newReadings: [DeviceReading]) {
        var newReadings = newReadings
        applyBusyHysteresis(to: &newReadings)
        readings = newReadings

        func sorted(_ r: [DeviceReading]) -> [DeviceReading] {
            r.sorted { $0.identity.displayName < $1.identity.displayName }
        }
        let usb = sorted(newReadings.filter { $0.identity.interconnect.isUSB })
        let external = sorted(newReadings.filter {
            !$0.identity.interconnect.isUSB && !$0.identity.isInternal
        })
        let internalDrives = sorted(newReadings.filter {
            !$0.identity.interconnect.isUSB && $0.identity.isInternal
        })

        let structuralChange = usb.count != usbDevices.count
            || external.count != externalDevices.count
            || internalDrives.count != internalDevices.count

        // History is only kept for drives that are actually on screen.
        //
        // The internal SSD produces background I/O continuously. Keeping its
        // graph up to date while it is hidden mutates the shared `history`
        // dictionary on every tick, which invalidates every view that reads
        // history — including the window showing a completely idle USB drive.
        // Watching nothing should cost nothing.
        let watched = showInternalDrives
            ? newReadings
            : usb + external
        let watchedIDs = Set(watched.map(\.identity.id))

        let anyActive = watched.contains { $0.sample.totalBytesPerSecond > 0 }
        let decision = gate.advance(anyActive: anyActive, structuralChange: structuralChange)

        let live = watchedIDs

        if decision.accumulateHistory {
            sequence &+= 1
            let t = Double(monotonicNanos() &- startedAtNanos) / 1_000_000_000
            for reading in watched {
                var points = pendingHistory[reading.identity.id] ?? []
                points.append(GraphPoint(
                    id: sequence,
                    t: t,
                    read: reading.sample.readBytesPerSecond / 1_000_000,
                    write: reading.sample.writeBytesPerSecond / 1_000_000
                ))
                if points.count > Self.historyLength {
                    points.removeFirst(points.count - Self.historyLength)
                }
                pendingHistory[reading.identity.id] = points
            }
            historyDirty = true
        }
        // Forget history for anything unplugged, so a replug starts clean.
        if pendingHistory.keys.contains(where: { !live.contains($0) }) {
            pendingHistory = pendingHistory.filter { live.contains($0.key) }
            historyDirty = true
        }

        announceNewDevices(usb + external)

        guard decision.publish else { return }

        if usbDevices != usb { usbDevices = usb }
        if externalDevices != external { externalDevices = external }
        if internalDevices != internalDrives { internalDevices = internalDrives }
        if historyDirty {
            history = pendingHistory
            historyDirty = false
        }

        let targets = Self.benchmarkTargets(from: usb + external + internalDrives)
        if benchmarkTargets != targets { benchmarkTargets = targets }

        let totalRate = usb.reduce(0.0) { $0 + $1.sample.totalBytesPerSecond }
        let text = (usb.isEmpty || totalRate <= 64 * 1024) ? "" : Format.menuBar(totalRate)
        if menuBarText != text { menuBarText = text }
        if usbDeviceCount != usb.count { usbDeviceCount = usb.count }

        if let id = selectedDeviceID, !live.contains(id) {
            selectedDeviceID = visibleDevices.first?.identity.id
        }
        if let volume = benchmarkVolume,
           !targets.contains(where: { $0.volume.mountPath == volume.mountPath }) {
            benchmarkVolume = nil
        }
    }

    /// Turns raw per-tick activity into a settled display state.
    private func applyBusyHysteresis(to readings: inout [DeviceReading]) {
        for index in readings.indices {
            let id = readings[index].identity.id
            // `gate.tick` has not been advanced for this tick yet, which is
            // fine — every comparison uses the same origin.
            if readings[index].sample.isActive { lastBusyTick[id] = gate.tick }
            let since = gate.tick - (lastBusyTick[id] ?? Int.min / 2)
            readings[index].isBusy = since <= Self.busyLingerTicks
        }
        let live = Set(readings.map(\.identity.id))
        lastBusyTick = lastBusyTick.filter { live.contains($0.key) }
    }

    /// A drive is announced once, when it first appears. The diagnosis itself
    /// decides whether the notification is worth posting at all.
    private func announceNewDevices(_ devices: [DeviceReading]) {
        let present = Set(devices.map(\.identity.id))
        for reading in devices where !announced.contains(reading.identity.id) {
            announced.insert(reading.identity.id)
            let identity = reading.identity
            Task { await Notifier.shared.deviceConnected(identity) }
        }
        for gone in announced.subtracting(present) {
            announced.remove(gone)
            Notifier.shared.forget(deviceID: gone)
        }

        for reading in devices {
            let errors = reading.sample.readErrors + reading.sample.writeErrors
            guard errors > 0 || reading.sample.retries > 0 else { continue }
            let identity = reading.identity
            let retries = reading.sample.retries
            Task { await Notifier.shared.errorsDetected(on: identity,
                                                        errors: errors, retries: retries) }
        }
    }

    // MARK: - Eject

    func eject(_ identity: DeviceIdentity) {
        // The IOKit `Ejectable` flag is not a safety check on its own.
        guard !identity.isInternal,
              !identity.volumes.contains(where: { $0.isBootVolume }) else {
            ejectFailure = "That is a system drive and cannot be ejected."
            return
        }
        if benchmarkProgress.phase.isRunning,
           let running = benchmarkVolume,
           identity.volumes.contains(where: { $0.mountPath == running.mountPath }) {
            ejectFailure = "A speed test is running on this drive. Cancel it first."
            return
        }
        let whole = identity.bsdName
        // Every mounted volume, including APFS volumes on synthesized devices,
        // which unmounting the physical disk would miss.
        let volumes = identity.volumes.map(\.bsdName)
        Task { [weak self] in
            let failure = await self?.ejector.eject(wholeDiskBSD: whole, volumeBSDNames: volumes)
            await MainActor.run { self?.ejectFailure = failure }
        }
    }

    /// Volumes a benchmark may legally target: mounted, writable, not a system
    /// volume. Ordered USB first, because that is almost always the intent.
    static func benchmarkTargets(from readings: [DeviceReading]) -> [BenchmarkTarget] {
        readings.flatMap { reading in
            reading.identity.volumes
                .filter { !$0.isBootVolume && $0.isWritable }
                .map {
                    BenchmarkTarget(
                        label: reading.identity.usbLink?.lineRateLabel
                            ?? reading.identity.interconnect.label,
                        volume: $0
                    )
                }
        }
    }

    // MARK: - Benchmark

    func startBenchmark() {
        guard let volume = benchmarkVolume, !benchmarkProgress.phase.isRunning else { return }
        benchmarkResults = nil
        previousRun = nil
        benchmarkDrive = device(owning: volume)

        let driveKey = Self.historyKey(for: benchmarkDrive)
        Task { [weak self] in
            let prior = await BenchmarkHistory.shared.previousRun(forDriveKey: driveKey)
            await MainActor.run { self?.previousRun = prior }
        }

        benchmarkProgress = BenchmarkProgress(phase: .preparing, message: "Starting")
        benchmark.run(
            volume: volume,
            testBytes: benchmarkSizeBytes,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.benchmarkProgress = progress }
            },
            onFinish: { [weak self] results in
                Task { @MainActor in self?.finishBenchmark(results) }
            }

        )
    }

    private func finishBenchmark(_ results: BenchmarkResults) {
        // A cancelled run carries no error, so guarding on `error == nil` alone
        // filed half-finished runs in the history and rendered them as real
        // results — permanently poisoning the "compared to last time" baseline.
        guard benchmarkProgress.phase != .cancelled else {
            benchmarkResults = nil
            return
        }
        benchmarkResults = results
        guard results.error == nil else { return }

        let record = BenchmarkRecord(
            date: Date(),
            driveKey: Self.historyKey(for: benchmarkDrive),
            driveName: benchmarkDrive?.displayName ?? results.volumeName,
            volumeName: results.volumeName,
            testBytes: results.testBytes,
            sequentialReadMBps: results.sequentialReadMBps,
            sequentialWriteMBps: results.sequentialWriteMBps,
            sequentialWriteSustainedMBps: results.sequentialWriteSustainedMBps,
            sequentialReadQD4MBps: results.sequentialReadQD4MBps,
            randomReadIOPS: results.randomReadIOPS,
            randomWriteIOPS: results.randomWriteIOPS
        )
        Task { await BenchmarkHistory.shared.record(record) }
    }

    /// The link ceiling of the drive actually under test, which is not
    /// necessarily the one selected in the sidebar.
    var benchmarkDriveCeilingMBps: Double? {
        guard let volume = benchmarkVolume else { return selected?.identity.usbLink?.practicalCeilingMBps }
        return device(owning: volume)?.usbLink?.practicalCeilingMBps
    }

    private func device(owning volume: VolumeRef) -> DeviceIdentity? {
        (usbDevices + externalDevices + internalDevices)
            .first { $0.identity.volumes.contains { $0.mountPath == volume.mountPath } }?
            .identity
    }

    /// Serial number when the drive publishes one; otherwise a stable-enough
    /// composite. Never the BSD name, which is reused across replugs.
    static func historyKey(for identity: DeviceIdentity?) -> String {
        guard let identity else { return "unknown" }
        if !identity.serialNumber.isEmpty { return identity.serialNumber }
        return "\(identity.vendorName)/\(identity.productName)/\(identity.capacityBytes)"
    }

    func cancelBenchmark() { benchmark.cancel() }

    func applyAdaptiveSamplingPreference() {
        let enabled = Preferences.shared.adaptiveSampling
        let sampler = self.sampler
        Task { await sampler.setAdaptive(enabled) }
    }

    /// Opens the sheet, defaulting the target to the selected drive's first
    /// testable volume so the common case is one click.
    func beginSpeedTest() {
        // Always retarget to the drive currently selected. Keeping a previous
        // choice meant the toolbar button — which sits next to that drive's
        // name — could quietly write gigabytes to a different device.
        let selectedPaths = Set(selected?.identity.volumes.map(\.mountPath) ?? [])
        if let onSelected = benchmarkTargets.first(where: { selectedPaths.contains($0.volume.mountPath) }) {
            benchmarkVolume = onSelected.volume
        } else if benchmarkVolume == nil
                    || !benchmarkTargets.contains(where: { $0.volume.mountPath == benchmarkVolume?.mountPath }) {
            benchmarkVolume = benchmarkTargets.first?.volume
        }
        resetSpeedTest()
        showingSpeedTest = true
    }

    func endSpeedTest() {
        if benchmarkProgress.phase.isRunning { benchmark.cancel() }
        showingSpeedTest = false
    }

    func resetSpeedTest() {
        benchmarkResults = nil
        benchmarkProgress = BenchmarkProgress()
    }
}
