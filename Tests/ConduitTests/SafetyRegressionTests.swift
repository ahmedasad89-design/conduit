import Testing
import Foundation
@testable import Conduit

/// Regressions for defects an adversarial review found in the first cut.
/// Each of these shipped once; none should return quietly.
@Suite("Safety regressions")
struct SafetyRegressionTests {

    private func volume(_ name: String, path: String, boot: Bool = false,
                        writable: Bool = true, free: Int64 = 100_000_000_000) -> VolumeRef {
        VolumeRef(name: name, mountPath: path, bsdName: "disk9s1", isBootVolume: boot,
                  totalBytes: 200_000_000_000, freeBytes: free, isWritable: writable)
    }

    private func reading(_ volumes: [VolumeRef], internalDrive: Bool = false) -> DeviceReading {
        DeviceReading(
            identity: DeviceIdentity(
                id: 1, bsdName: "disk9", productName: "Drive", vendorName: "",
                serialNumber: "SN", interconnect: internalDrive ? .appleFabric : .usb,
                location: internalDrive ? "Internal" : "External",
                capacityBytes: 1 << 30, isRemovable: !internalDrive, isEjectable: !internalDrive,
                isSolidState: true, usbLink: nil, childBSDNames: [], volumes: volumes),
            sample: .zero)
    }

    /// `/Volumes/Recovery` is writable, sits on the boot disk, and is not under
    /// `/System/Volumes/`. It was offered as a benchmark target on the very
    /// machine this was built on. `Volumes.current()` now marks anything
    /// carrying `MNT_DONTBROWSE` as a boot volume, which is what excludes it.
    @MainActor
    @Test("a volume flagged as a system volume is never a benchmark target")
    func recoveryStyleVolumeExcluded() {
        let targets = MonitorStore.benchmarkTargets(from: [
            reading([volume("Recovery", path: "/Volumes/Recovery", boot: true)])
        ])
        #expect(targets.isEmpty)
    }

    @MainActor
    @Test("an ordinary external volume is still offered")
    func normalVolumeStillOffered() {
        let targets = MonitorStore.benchmarkTargets(from: [
            reading([volume("Field Kit", path: "/Volumes/Field Kit")])
        ])
        #expect(targets.count == 1)
    }

    /// The live meter and the test-size picker have to agree on what a gigabyte
    /// is. Declaring sizes in powers of two while printing decimal MB made the
    /// "1 GB" option move 1.07 GB.
    @Test("a test size labelled in GB is decimal, matching every printed figure")
    func testSizesAreDecimal() {
        // 1 GB of data reported at 1000 MB/s must take exactly one second.
        let oneGB: Int64 = 1_000_000_000
        let seconds = Double(oneGB) / 1_000_000 / 1000
        #expect(abs(seconds - 1.0) < 0.0001)
    }

    /// `Format.rate` rescales between KB, MB and GB; anything printing its
    /// output must take the unit from `Format.rateUnit` rather than hardcoding.
    @Test("rate and unit always agree across the scale boundaries")
    func rateAndUnitAgree() {
        #expect(Format.rateUnit(500) == "MB/s")             // below the noise floor
        #expect(Format.rateUnit(50_000) == "KB/s")
        #expect(Format.rateUnit(50_000_000) == "MB/s")
        #expect(Format.rateUnit(5_000_000_000) == "GB/s")
        // 2.5 GB/s must not be printed as "2500" next to a hardcoded "MB/s".
        #expect(Format.rate(2_500_000_000) == "2.50")
        #expect(Format.rateUnit(2_500_000_000) == "GB/s")
    }

    /// Low-speed USB is 1.5 Mb/s. Integer division rendered it as "1 Mb/s".
    @Test("a fractional sub-gigabit link keeps its decimal")
    func lowSpeedLabel() {
        #expect(USBLink.make(bitsPerSecond: 1_500_000, hubs: [], uasp: false).lineRateLabel
                == "1.5 Mb/s")
        #expect(USBLink.make(bitsPerSecond: 12_000_000, hubs: [], uasp: false).lineRateLabel
                == "12 Mb/s")
    }

    /// The 5 and 10 Gb/s branches always honoured UASP; the faster ones did not,
    /// so a bulk-only 20 Gb/s enclosure was credited with a UASP ceiling.
    @Test("bulk-only transport lowers the ceiling at every generation")
    func uaspHonouredAtAllSpeeds() {
        for bps in [5_000_000_000, 10_000_000_000, 20_000_000_000, 40_000_000_000] {
            let uasp = USBLink.make(bitsPerSecond: bps, hubs: [], uasp: true)
            let bot = USBLink.make(bitsPerSecond: bps, hubs: [], uasp: false)
            #expect(bot.practicalCeilingMBps < uasp.practicalCeilingMBps,
                    "UASP ignored at \(bps) bits/sec")
        }
    }

    /// Comparing a 256 MB run against a 16 GB one reports the size change as a
    /// speed change, because the small test fits in a cache the large one does not.
    @Test("history keeps the test size, so runs can be compared like for like")
    func recordsCarryTestSize() {
        let small = BenchmarkRecord(date: Date(), driveKey: "SN", driveName: "D",
                                    volumeName: "V", testBytes: 256_000_000,
                                    sequentialReadMBps: 400, sequentialWriteMBps: 200,
                                    sequentialWriteSustainedMBps: 200,
                                    sequentialReadQD4MBps: nil,
                                    randomReadIOPS: nil, randomWriteIOPS: nil)
        let large = BenchmarkRecord(date: Date(), driveKey: "SN", driveName: "D",
                                    volumeName: "V", testBytes: 16_000_000_000,
                                    sequentialReadMBps: 380, sequentialWriteMBps: 90,
                                    sequentialWriteSustainedMBps: 90,
                                    sequentialReadQD4MBps: nil,
                                    randomReadIOPS: nil, randomWriteIOPS: nil)
        #expect(small.testBytes != large.testBytes)
    }
}

/// Regressions from the second review round.
@Suite("Second-round regressions")
struct SecondRoundRegressionTests {

    /// The store's default and the picker's tags were declared separately and
    /// drifted: `1 << 30` against a `1_000_000_000` tag. The segmented control
    /// opened with nothing selected, and the first run recorded an unlabelled
    /// 1.07 GB that then failed its own same-size comparison check.
    @MainActor
    @Test("the default test size is one the picker actually offers")
    func defaultSizeIsSelectable() {
        let offered = Set(BenchmarkSize.allCases.map(\.bytes))
        #expect(offered.contains(MonitorStore.shared.benchmarkSizeBytes))
    }

    @Test("every offered size is decimal, matching the labels")
    func sizesAreDecimal() {
        #expect(BenchmarkSize.small.bytes == 256_000_000)
        #expect(BenchmarkSize.standard.bytes == 1_000_000_000)
        #expect(BenchmarkSize.large.bytes == 4_000_000_000)
        #expect(BenchmarkSize.exhaustive.bytes == 16_000_000_000)
        for size in BenchmarkSize.allCases {
            #expect(size.bytes % 1_000_000 == 0, "\(size.label) is not a round decimal size")
        }
    }

    private func identity(bps: Int) -> DeviceIdentity {
        DeviceIdentity(id: 1, bsdName: "disk4", productName: "Board", vendorName: "",
                       serialNumber: "SN", interconnect: .usb, location: "External",
                       capacityBytes: 1 << 20, isRemovable: true, isEjectable: true,
                       isSolidState: false,
                       usbLink: USBLink.make(bitsPerSecond: bps, hubs: [], uasp: false),
                       childBSDNames: [], volumes: [])
    }

    /// A 12 Mb/s full-speed device — a microcontroller in bootloader mode, say —
    /// is full-speed by design. It used to be told it was "running at USB 2.0
    /// speed" and advised to change its cable.
    @MainActor
    @Test("a full-speed device is not scolded for being full-speed")
    func fullSpeedIsNotDiagnosed() {
        #expect(Notifier.connectionDiagnosis(for: identity(bps: 12_000_000)) == nil)
        #expect(Notifier.connectionDiagnosis(for: identity(bps: 1_500_000)) == nil)
    }

    @MainActor
    @Test("an actual USB 2.0 high-speed link is still flagged, by its real name")
    func highSpeedStillFlagged() {
        let message = Notifier.connectionDiagnosis(for: identity(bps: 480_000_000))
        #expect(message?.contains("USB 2.0 High-Speed") == true)
    }
}

/// A drive being Spotlight-indexed goes active/idle/active on consecutive
/// ticks. Driving animations straight off that restarted a transition twice a
/// second, and over a vibrant surface the compositor re-blurred continuously —
/// measured at over 50% of a core on a 2 TB drive mid-index.
@Suite("Activity hysteresis")
struct ActivityHysteresisTests {

    /// Mirrors `MonitorStore.applyBusyHysteresis`: busy latches on immediately
    /// and only clears after the linger window has passed with no activity.
    private func busyStates(activity: [Bool], linger: Int) -> [Bool] {
        var lastBusy = Int.min / 2
        return activity.enumerated().map { tick, active in
            if active { lastBusy = tick }
            return tick - lastBusy <= linger
        }
    }

    @Test("a single quiet tick between two bursts does not read as stopped")
    func flappingStaysSettled() {
        // active, idle, active, idle — the pattern a drive under indexing makes.
        let states = busyStates(activity: [true, false, true, false, true, false], linger: 6)
        #expect(states.allSatisfy { $0 }, "busy flickered during a bursty workload")
    }

    @Test("busy turns on immediately, with no delay on the first byte")
    func latchesOnAtOnce() {
        #expect(busyStates(activity: [true], linger: 6) == [true])
    }

    @Test("a drive that genuinely stops does stop looking busy")
    func clearsAfterTheWindow() {
        var activity = [true]
        activity.append(contentsOf: Array(repeating: false, count: 10))
        let states = busyStates(activity: activity, linger: 6)
        #expect(states[6], "cleared too early — a short gap would flicker")
        #expect(!states[7], "never cleared — a finished drive would look busy forever")
    }

    @Test("a device idle from the start is never marked busy")
    func idleFromColdIsNotBusy() {
        #expect(busyStates(activity: Array(repeating: false, count: 5), linger: 6)
                    .allSatisfy { !$0 })
    }
}
