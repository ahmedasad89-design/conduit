import SwiftUI

/// The speed test as a flow rather than a tab.
///
/// A tab implies two co-equal modes and leaves a dead panel sitting there
/// whenever you are not benchmarking. A sheet matches what this actually is: a
/// deliberate, bounded action you start, watch, and finish — setup, running,
/// result, each replacing the last.
struct SpeedTestSheet: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if store.benchmarkProgress.phase.isRunning {
                    running
                } else if let results = store.benchmarkResults {
                    ResultsView(results: results, previous: store.previousRun)
                } else {
                    setup
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Speed Test").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if store.benchmarkResults != nil && !store.benchmarkProgress.phase.isRunning {
                Button("Test Again") { store.resetSpeedTest() }
            }
            Spacer()
            if store.benchmarkProgress.phase.isRunning {
                Button("Cancel", role: .cancel) { store.cancelBenchmark() }
            } else if store.benchmarkResults == nil {
                Button("Cancel", role: .cancel) { store.endSpeedTest() }
                Button("Start") { store.startBenchmark() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.benchmarkVolume == nil)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { store.endSpeedTest() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Setup

    private var setup: some View {
        Form {
            if store.benchmarkTargets.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing to Test", systemImage: "externaldrive.badge.questionmark")
                    } description: {
                        Text("Connect a writable drive. System volumes cannot be tested.")
                    }
                }
            } else {
                Section("Target") {
                    // Tagged by mount path, not by the whole `VolumeRef`.
                    // `VolumeRef` includes `freeBytes`, so tagging by value made
                    // the visible selection clear itself every time free space
                    // changed, while the stored choice stayed put.
                    Picker("Volume", selection: Binding(
                        get: { store.benchmarkVolume?.mountPath ?? "" },
                        set: { path in
                            store.benchmarkVolume = store.benchmarkTargets
                                .first { $0.volume.mountPath == path }?.volume
                        }
                    )) {
                        Text("Choose…").tag("")
                        ForEach(store.benchmarkTargets) { target in
                            Text("\(target.volume.name) — \(target.label)")
                                .tag(target.volume.mountPath)
                        }
                    }
                    Picker("Test size", selection: $store.benchmarkSizeBytes) {
                        ForEach(BenchmarkSize.allCases) { Text($0.label).tag($0.bytes) }
                    }
                    .pickerStyle(.segmented)
                }

                if let volume = store.benchmarkVolume {
                    Section {
                        LabeledContent("Free space", value: Format.bytes(volume.freeBytes))
                        LabeledContent("Scratch file", value: volume.mountPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } footer: {
                        Text("Writes one temporary file, reads it back, then deletes it. "
                             + "Nothing else on the volume is touched.")
                    }
                }

                Section("Method") {
                    Text("Reads and writes bypass the system cache, so the result describes the "
                         + "drive rather than this Mac's memory. Two write figures are reported: "
                         + "the rate the drive accepted data, and the rate once it had committed "
                         + "everything to media. On a drive with a large write buffer those differ, "
                         + "and the committed one is the honest number.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: 22) {
            Spacer()
            Gauge(value: min(1, store.benchmarkProgress.instantMBps / gaugeCeiling)) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 2) {
                    // `Format.rate` rescales between KB, MB and GB, so the unit
                    // has to come from the same call — a hardcoded "MB/s" here
                    // labelled a gigabyte-per-second number as megabytes.
                    Text(Format.rate(bytesPerSecond))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(Format.rateUnit(bytesPerSecond))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(phaseTint)
            .scaleEffect(2.1)
            .frame(height: 150)

            VStack(spacing: 6) {
                Text(store.benchmarkProgress.phase.rawValue)
                    .font(.headline)
                ProgressView(value: store.benchmarkProgress.fraction)
                    .tint(phaseTint)
                    .frame(width: 280)
            }
            Spacer()
        }
        .padding(20)
    }

    private var bytesPerSecond: Double { store.benchmarkProgress.instantMBps * 1_000_000 }

    /// The gauge needs an upper bound before the drive's speed is known. The
    /// link's practical ceiling is the honest one; fall back to something
    /// generous rather than pinning the needle.
    private var gaugeCeiling: Double {
        store.benchmarkDriveCeilingMBps ?? 1000
    }

    private var phaseTint: Color {
        switch store.benchmarkProgress.phase {
        case .sequentialWrite, .randomWrite: Ink.write
        case .sequentialRead, .randomRead:   Ink.read
        default:                             Color.secondary
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    var results: BenchmarkResults
    var previous: BenchmarkRecord?

    var body: some View {
        Form {
            if let error = results.error {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Ink.problem)
                }
            } else {
                Section(results.volumeName) {
                    ValueRow("Sequential read", Format.mbps(results.sequentialReadMBps),
                             tint: Ink.read)
                    ValueRow("Sequential read, 4 at once",
                             Format.mbps(results.sequentialReadQD4MBps),
                             tint: Ink.read,
                             help: "Four reads in flight at once. An NVMe drive in a USB "
                                 + "enclosure is often limited by per-command latency rather "
                                 + "than bandwidth, and only shows its real speed here.")
                    ValueRow("Sequential write", Format.mbps(results.sequentialWriteMBps),
                             tint: Ink.write)
                    ValueRow("Write committed to media",
                             Format.mbps(results.sequentialWriteSustainedMBps))
                    ValueRow("Random 4K read", Format.iops(results.randomReadIOPS) + " IOPS")
                    ValueRow("Random 4K write", Format.iops(results.randomWriteIOPS) + " IOPS")
                    if let range = writeRange {
                        ValueRow("Write range", range,
                                 help: "Slowest and fastest moment during the write. A wide "
                                     + "range means the drive stalled repeatedly rather than "
                                     + "holding a steady rate.")
                    }
                }

                if comparablePrevious != nil {
                    Section("Compared to last time") { comparison }
                }

                if !results.sustainedIsVerified {
                    Section {
                        Advice(level: .warning, symbol: "exclamationmark.triangle.fill",
                               message: "This volume's filesystem refused a full flush to media, "
                                      + "so the committed figure may still include the drive's "
                                      + "own buffer. Common on exFAT and FAT.")
                    }
                }

                if results.sustainedIsVerified,
                   let streaming = results.sequentialWriteMBps,
                   let sustained = results.sequentialWriteSustainedMBps,
                   streaming > sustained * 1.25 {
                    Section {
                        Advice(level: .warning, symbol: "info.circle.fill",
                               message: "The drive accepted data faster than it committed it. "
                                      + "\(Format.mbps(sustained)) is the honest sustained "
                                      + "write speed.")
                    }
                }

                if !results.writeCurve.isEmpty {
                    Section("Write over time") {
                        BenchmarkCurveChart(curve: results.writeCurve, tint: Ink.write)
                        Text(curveNote)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !results.readCurve.isEmpty {
                    Section("Read over time") {
                        BenchmarkCurveChart(curve: results.readCurve, tint: Ink.read)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Slowest and fastest sampled moment of the write. The average alone hides
    /// a drive that alternates between 256 and 59 MB/s.
    private var writeRange: String? {
        let values = results.writeCurve.map(\.1)
        guard let lo = values.min(), let hi = values.max(), values.count > 2 else { return nil }
        return "\(Format.mbps(lo)) – \(Format.mbps(hi))"
    }

    /// Only shown when the previous run used the same test size. Comparing a
    /// 256 MB run against a 16 GB one reports the size change as a speed
    /// change — a drive whose cache covers the small test but not the large one
    /// would look like it had halved in speed overnight.
    private var comparablePrevious: BenchmarkRecord? {
        guard let previous, previous.testBytes == results.testBytes else { return nil }
        return previous
    }

    @ViewBuilder
    private var comparison: some View {
        if let previous = comparablePrevious {
            LabeledContent("Previous run") {
                Text(previous.date.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            delta("Read", now: results.sequentialReadMBps, then: previous.sequentialReadMBps)
            delta("Write", now: results.sequentialWriteMBps, then: previous.sequentialWriteMBps)
        }
    }

    /// A drive getting slower over time is the thing a one-shot benchmark can
    /// never tell you, and the main reason runs are stored at all.
    @ViewBuilder
    private func delta(_ label: String, now: Double?, then: Double?) -> some View {
        if let now, let then, then > 0 {
            let change = (now - then) / then
            LabeledContent(label) {
                HStack(spacing: 5) {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(String(format: "%+.0f%%", change * 100))
                        .monospacedDigit()
                }
                .foregroundStyle(abs(change) < 0.05 ? Color.secondary
                                                    : (change > 0 ? Ink.healthy : Ink.problem))
            }
        }
    }

    /// A single sustained drop is a cache running out; a repeating sawtooth is
    /// the controller stalling to erase blocks. They look similar on the graph
    /// and mean different things, so the app says which it saw.
    private var curveNote: String {
        let values = results.writeCurve.map(\.1)
        guard values.count >= 5, let peak = values.max(), peak > 0 else {
            return "Throughput across the write."
        }
        let head = values.prefix(max(1, values.count / 5))
        let tail = values.suffix(max(1, values.count / 5))
        let opening = head.reduce(0, +) / Double(head.count)
        let settled = tail.reduce(0, +) / Double(tail.count)
        let dips = values.filter { $0 < peak * 0.5 }.count

        if settled < opening * 0.7 {
            return "Opened at \(Format.mbps(opening)) and settled at \(Format.mbps(settled)) — "
                 + "the drive's fast cache filled and it dropped to its native write speed."
        }
        if dips > values.count / 5 {
            return "A repeating sawtooth rather than a single cliff — periodic stalls while the "
                 + "controller erases blocks, typical of a drive without a DRAM cache."
        }
        return "Held a steady rate throughout, with no cache cliff."
    }
}
