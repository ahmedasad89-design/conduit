import Foundation

/// One stored benchmark run.
struct BenchmarkRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date
    /// Drive serial number — stable across replugs, unlike the BSD name.
    var driveKey: String
    var driveName: String
    var volumeName: String
    var testBytes: Int64
    var sequentialReadMBps: Double?
    var sequentialWriteMBps: Double?
    var sequentialWriteSustainedMBps: Double?
    var sequentialReadQD4MBps: Double?
    var randomReadIOPS: Double?
    var randomWriteIOPS: Double?
}

/// Keeps past runs so the app can answer the question a one-shot benchmark
/// cannot: *is this drive getting slower?*
///
/// Plain JSON in Application Support. A database would be more machinery than a
/// list of a few hundred records deserves, and a readable file is easier to
/// delete if it ever goes wrong.
actor BenchmarkHistory {

    static let shared = BenchmarkHistory()

    /// Enough to see a trend without the file growing without bound.
    private static let maxRecordsPerDrive = 50

    private let url: URL
    private var records: [BenchmarkRecord]?

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = base.appendingPathComponent("Conduit", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.url = folder.appendingPathComponent("benchmarks.json")
        }
    }

    private func load() -> [BenchmarkRecord] {
        if let records { return records }
        let decoded: [BenchmarkRecord]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode([BenchmarkRecord].self, from: data) {
            decoded = parsed
        } else {
            decoded = []
        }
        records = decoded
        return decoded
    }

    private func persist(_ records: [BenchmarkRecord]) {
        self.records = records
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The most recent previous run for this drive, before the one just added.
    func previousRun(forDriveKey key: String) -> BenchmarkRecord? {
        load()
            .filter { $0.driveKey == key }
            .max { $0.date < $1.date }
    }

    func record(_ record: BenchmarkRecord) {
        var all = load()
        all.append(record)

        // Trim per drive rather than globally, so a drive you test rarely does
        // not get evicted by one you test constantly.
        let byDrive = Dictionary(grouping: all, by: \.driveKey)
        all = byDrive.values.flatMap { runs in
            runs.sorted { $0.date > $1.date }.prefix(Self.maxRecordsPerDrive)
        }
        .sorted { $0.date < $1.date }

        persist(all)
    }

    func runs(forDriveKey key: String) -> [BenchmarkRecord] {
        load().filter { $0.driveKey == key }.sorted { $0.date > $1.date }
    }
}
