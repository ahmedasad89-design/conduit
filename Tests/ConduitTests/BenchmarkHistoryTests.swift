import Testing
import Foundation
@testable import Conduit

@Suite("Benchmark history")
struct BenchmarkHistoryTests {

    private func tempStore() -> (BenchmarkHistory, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conduit-history-\(UUID().uuidString).json")
        return (BenchmarkHistory(url: url), url)
    }

    private func record(key: String, read: Double, at date: Date) -> BenchmarkRecord {
        BenchmarkRecord(date: date, driveKey: key, driveName: "SanDisk",
                        volumeName: "Field Kit", testBytes: 1 << 30,
                        sequentialReadMBps: read, sequentialWriteMBps: 182,
                        sequentialWriteSustainedMBps: 181, sequentialReadQD4MBps: nil,
                        randomReadIOPS: 3253, randomWriteIOPS: 577)
    }

    @Test("a run survives a round trip to disk")
    func roundTrip() async throws {
        let (history, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await history.record(record(key: "SN-1", read: 378.6, at: Date()))
        let reloaded = BenchmarkHistory(url: url)
        let runs = await reloaded.runs(forDriveKey: "SN-1")
        #expect(runs.count == 1)
        #expect(runs.first?.sequentialReadMBps == 378.6)
    }

    @Test("history is filed per drive, so one drive's runs never surface under another")
    func perDrive() async throws {
        let (history, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await history.record(record(key: "SN-1", read: 378, at: Date()))
        await history.record(record(key: "SN-2", read: 42, at: Date()))
        #expect(await history.runs(forDriveKey: "SN-1").count == 1)
        #expect(await history.runs(forDriveKey: "SN-2").first?.sequentialReadMBps == 42)
    }

    @Test("the previous run is the most recent one, not merely the last written")
    func mostRecent() async throws {
        let (history, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        await history.record(record(key: "SN-1", read: 100, at: now))
        await history.record(record(key: "SN-1", read: 200, at: now.addingTimeInterval(-3600)))
        #expect(await history.previousRun(forDriveKey: "SN-1")?.sequentialReadMBps == 100)
    }

    /// Trimming has to be per drive. Trimming globally would let a drive tested
    /// every day evict the entire history of one tested twice a year.
    @Test("trimming keeps each drive's own window")
    func trimsPerDrive() async throws {
        let (history, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = Date()
        for i in 0..<60 {
            await history.record(record(key: "Busy", read: Double(i),
                                        at: base.addingTimeInterval(Double(i))))
        }
        await history.record(record(key: "Rare", read: 999, at: base))

        #expect(await history.runs(forDriveKey: "Busy").count == 50)
        #expect(await history.runs(forDriveKey: "Rare").count == 1)
    }

    @Test("a missing or corrupt file reads as empty rather than throwing")
    func corruptFile() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conduit-bad-\(UUID().uuidString).json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let history = BenchmarkHistory(url: url)
        #expect(await history.runs(forDriveKey: "anything").isEmpty)
    }
}

@Suite("History keys")
struct HistoryKeyTests {

    private func identity(serial: String, vendor: String = "SanDisk",
                          product: String = "3.2Gen1") -> DeviceIdentity {
        DeviceIdentity(id: 1, bsdName: "disk4", productName: product, vendorName: vendor,
                       serialNumber: serial, interconnect: .usb, location: "External",
                       capacityBytes: 123_009_761_280, isRemovable: true, isEjectable: true,
                       isSolidState: true, usbLink: nil, childBSDNames: [], volumes: [])
    }

    /// The BSD name is reused across replugs, so it can never be the key.
    @MainActor
    @Test("serial number is preferred and is independent of the BSD name")
    func prefersSerial() {
        #expect(MonitorStore.historyKey(for: identity(serial: "ABC123")) == "ABC123")
    }

    @MainActor
    @Test("a drive with no serial still gets a stable composite key")
    func fallsBackToComposite() {
        let key = MonitorStore.historyKey(for: identity(serial: ""))
        #expect(key.contains("SanDisk"))
        #expect(key.contains("3.2Gen1"))
        #expect(key != "unknown")
    }

    @MainActor
    @Test("no device at all is still keyable rather than crashing")
    func noDevice() {
        #expect(MonitorStore.historyKey(for: nil) == "unknown")
    }
}
