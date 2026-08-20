import Testing
@testable import Conduit

/// The counter maths. Every rule here was derived from measurement rather than
/// documentation, and none of them can be exercised on demand against real
/// hardware — you cannot ask a drive to be unplugged mid-tick.
@Suite("Throughput rate maths")
struct SamplerRateTests {

    private func counters(at nanos: UInt64,
                          read: Int64 = 0, written: Int64 = 0,
                          reads: Int64 = 0, writes: Int64 = 0,
                          readTime: Int64 = 0, writeTime: Int64 = 0,
                          readErrors: Int64 = 0, writeErrors: Int64 = 0,
                          retries: Int64 = 0) -> RawCountersSnapshot {
        RawCountersSnapshot(bytesRead: read, bytesWritten: written,
                            opsRead: reads, opsWritten: writes,
                            totalTimeRead: readTime, totalTimeWrite: writeTime,
                            errorsRead: readErrors, errorsWrite: writeErrors,
                            retriesRead: retries, retriesWrite: 0,
                            timestamp: nanos)
    }

    @Test("the first sample has no baseline and must report nothing, not everything")
    func firstSampleIsZero() {
        // Counters are cumulative since the driver attached. Treating the first
        // reading as a delta would report gigabytes-per-second on launch.
        let sample = ThroughputSampler.rate(from: nil, to: counters(at: 1_000, read: 999_999_999))
        #expect(sample == .zero)
    }

    @Test("bytes over measured elapsed time gives the rate")
    func basicRate() {
        let t0 = counters(at: 1_000_000_000, read: 0, written: 0)
        let t1 = counters(at: 2_000_000_000, read: 100_000_000, written: 50_000_000)
        let sample = ThroughputSampler.rate(from: t0, to: t1)
        #expect(sample.readBytesPerSecond == 100_000_000)
        #expect(sample.writeBytesPerSecond == 50_000_000)
        #expect(sample.totalBytesPerSecond == 150_000_000)
    }

    /// Ticks fire late under load. Dividing by the nominal interval instead of
    /// the measured one inflates every number on screen.
    @Test("a late tick divides by real elapsed time, not the nominal interval")
    func lateTickIsNotInflated() {
        let t0 = counters(at: 0)
        let onTime = counters(at: 250_000_000, read: 25_000_000)   // 250 ms
        let late = counters(at: 500_000_000, read: 25_000_000)     // 500 ms, same bytes

        #expect(ThroughputSampler.rate(from: t0, to: onTime).readBytesPerSecond == 100_000_000)
        #expect(ThroughputSampler.rate(from: t0, to: late).readBytesPerSecond == 50_000_000)
    }

    /// Replug gives the same BSD name a fresh driver instance with zeroed
    /// counters. A naive subtraction produces a huge negative, which as an
    /// unsigned rate becomes a phantom multi-gigabyte spike.
    @Test("counters restarting after a replug report zero, never a negative or a spike")
    func counterResetIsAbsorbed() {
        let before = counters(at: 1_000_000_000, read: 5_000_000_000, written: 3_000_000_000,
                              reads: 10_000, writes: 8_000)
        let afterReplug = counters(at: 2_000_000_000, read: 1024, written: 0,
                                   reads: 2, writes: 0)
        let sample = ThroughputSampler.rate(from: before, to: afterReplug)
        #expect(sample.readBytesPerSecond == 0)
        #expect(sample.writeBytesPerSecond == 0)
        #expect(sample.readOpsPerSecond == 0)
        #expect(sample.totalBytesPerSecond >= 0)
    }

    @Test("a repeated timestamp cannot divide by zero")
    func zeroElapsed() {
        let t0 = counters(at: 5_000, read: 100)
        let t1 = counters(at: 5_000, read: 200)
        #expect(ThroughputSampler.rate(from: t0, to: t1) == .zero)
    }

    /// Latency comes from `Total Time / Operations`, in nanoseconds, because
    /// the dedicated `Latency Time` counters read zero on both Apple's NVMe
    /// driver and USB mass storage.
    @Test("latency is mean service time per operation, in microseconds")
    func latency() {
        let t0 = counters(at: 0)
        let t1 = counters(at: 1_000_000_000, reads: 100, readTime: 22_600_000)  // 226 µs/op
        let sample = ThroughputSampler.rate(from: t0, to: t1)
        #expect(sample.readLatencyMicros == 226)
        #expect(sample.readOpsPerSecond == 100)
    }

    @Test("no operations means no latency figure, rather than a misleading zero")
    func latencyIsNilWithoutOperations() {
        let t0 = counters(at: 0)
        let t1 = counters(at: 1_000_000_000)
        let sample = ThroughputSampler.rate(from: t0, to: t1)
        #expect(sample.readLatencyMicros == nil)
        #expect(sample.writeLatencyMicros == nil)
    }

    @Test("errors and retries are absolute totals, not per-second rates")
    func errorsAreCumulative() {
        let t0 = counters(at: 0, readErrors: 1, retries: 2)
        let t1 = counters(at: 1_000_000_000, readErrors: 7, writeErrors: 3, retries: 9)
        let sample = ThroughputSampler.rate(from: t0, to: t1)
        #expect(sample.readErrors == 7)
        #expect(sample.writeErrors == 3)
        #expect(sample.retries == 9)
    }

    @Test("a sample only counts as active once it clears the noise floor")
    func activityThreshold() {
        var trickle = DeviceSample.zero
        trickle.readBytesPerSecond = 1024          // background chatter
        #expect(!trickle.isActive)

        var realTransfer = DeviceSample.zero
        realTransfer.writeBytesPerSecond = 182_000_000
        #expect(realTransfer.isActive)
    }
}

@Suite("Volume safety")
struct VolumeSafetyTests {

    /// `/Users` lives on `/System/Volumes/Data`, which is a different device
    /// from `/`. Detecting the boot volume by comparing against `/` alone means
    /// happily benchmarking onto the user's home directory.
    @Test("every system path is refused, including the data volume that holds /Users")
    func systemPathsRefused() {
        #expect(Volumes.isSystemPath("/"))
        #expect(Volumes.isSystemPath("/System/Volumes/Data"))
        #expect(Volumes.isSystemPath("/System/Volumes/Preboot"))
        #expect(Volumes.isSystemPath("/System/Volumes/VM"))
        #expect(Volumes.isSystemPath("/private/var/vm"))
    }

    @Test("real external mounts are allowed")
    func externalAllowed() {
        #expect(!Volumes.isSystemPath("/Volumes/Field Kit"))
        #expect(!Volumes.isSystemPath("/Volumes/ConduitTest"))
    }
}

@Suite("Benchmark target selection")
struct BenchmarkTargetTests {

    private func reading(name: String,
                         interconnect: Interconnect,
                         volumes: [VolumeRef]) -> DeviceReading {
        DeviceReading(
            identity: DeviceIdentity(
                id: UInt64(abs(name.hashValue)),
                bsdName: "disk9",
                productName: name,
                vendorName: "",
                serialNumber: "SN-\(name)",
                interconnect: interconnect,
                location: interconnect == .appleFabric ? "Internal" : "External",
                capacityBytes: 1 << 30,
                isRemovable: true,
                isEjectable: true,
                isSolidState: true,
                usbLink: interconnect.isUSB
                    ? USBLink.make(bitsPerSecond: 5_000_000_000, hubs: [], uasp: true)
                    : nil,
                childBSDNames: [],
                volumes: volumes
            ),
            sample: .zero
        )
    }

    private func volume(_ name: String, boot: Bool = false, writable: Bool = true) -> VolumeRef {
        VolumeRef(name: name, mountPath: "/Volumes/\(name)", bsdName: "disk9s1",
                  isBootVolume: boot, totalBytes: 1 << 30, freeBytes: 1 << 29,
                  isWritable: writable)
    }

    @MainActor
    @Test("system and read-only volumes never appear as benchmark targets")
    func filtersUnsafeVolumes() {
        let readings = [
            reading(name: "SanDisk", interconnect: .usb, volumes: [volume("Field Kit")]),
            reading(name: "Internal", interconnect: .appleFabric,
                    volumes: [volume("Macintosh HD", boot: true)]),
            reading(name: "Locked", interconnect: .usb, volumes: [volume("ReadOnly", writable: false)])
        ]
        let targets = MonitorStore.benchmarkTargets(from: readings)
        #expect(targets.count == 1)
        #expect(targets.first?.volume.name == "Field Kit")
    }

    @MainActor
    @Test("the picker label carries the link rate, which is what informs the choice")
    func labelsCarryLinkRate() {
        let targets = MonitorStore.benchmarkTargets(from: [
            reading(name: "SanDisk", interconnect: .usb, volumes: [volume("Field Kit")])
        ])
        #expect(targets.first?.label == "5 Gb/s")
    }

    @MainActor
    @Test("a device with no mounted volume contributes no targets")
    func unmountedContributesNothing() {
        let targets = MonitorStore.benchmarkTargets(from: [
            reading(name: "Unmounted", interconnect: .usb, volumes: [])
        ])
        #expect(targets.isEmpty)
    }
}

@Suite("Queue depth")
struct QueueDepthTests {

    private func counters(at nanos: UInt64, reads: Int64 = 0, readTime: Int64 = 0) -> RawCountersSnapshot {
        RawCountersSnapshot(opsRead: reads, totalTimeRead: readTime, timestamp: nanos)
    }

    /// Service time accumulates per request, so overlapping requests make it
    /// exceed wall-clock. That ratio is average queue depth — presenting it as
    /// a percentage would produce a nonsensical "1660% utilised".
    @Test("accumulated service time above wall-clock reads as depth, not a percentage")
    func depthCanExceedOne() {
        let t0 = counters(at: 0)
        let t1 = counters(at: 1_000_000_000, reads: 500, readTime: 16_600_000_000)
        let depth = ThroughputSampler.rate(from: t0, to: t1).queueDepth
        #expect(depth != nil)
        #expect(abs((depth ?? 0) - 16.6) < 0.001)
    }

    @Test("a single serial request in flight is depth 1")
    func serialIsOne() {
        let t0 = counters(at: 0)
        let t1 = counters(at: 1_000_000_000, reads: 10, readTime: 1_000_000_000)
        #expect(abs((ThroughputSampler.rate(from: t0, to: t1).queueDepth ?? 0) - 1.0) < 0.001)
    }

    @Test("an idle interval reports no depth rather than zero")
    func idleIsNil() {
        let t0 = counters(at: 0)
        let t1 = counters(at: 1_000_000_000)
        #expect(ThroughputSampler.rate(from: t0, to: t1).queueDepth == nil)
    }
}
