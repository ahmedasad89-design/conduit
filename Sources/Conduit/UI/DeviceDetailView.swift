import SwiftUI

/// The live view of one device.
///
/// Structure over chrome: a hero block, the graph, then a grouped `Form`. The
/// grouped form is doing most of the work of making this feel like a Mac app —
/// it is the same container System Settings is built from, so the spacing,
/// dividers, section headers and label alignment all come from AppKit rather
/// than from hand-rolled cards.
/// `Equatable` on purpose, and applied with `.equatable()` at the call site.
///
/// `history` is a single dictionary keyed by device, so any device's points
/// changing invalidates every view that reads it — and the internal SSD churns
/// constantly from background system I/O. Without this, looking at an idle USB
/// drive still rebuilt this entire grouped form twice a second.
struct DeviceDetailView: View, Equatable {
    var reading: DeviceReading
    var points: [GraphPoint]

    private var identity: DeviceIdentity { reading.identity }
    private var sample: DeviceSample { reading.sample }

    /// One `Form`, with the hero and the graph as full-bleed rows at the top.
    ///
    /// The alternative — a `ScrollView` wrapping a `VStack` wrapping a `Form` —
    /// nests two scroll views and forces the inner one to a guessed height.
    /// System Settings puts its header inside the form for the same reason.
    var body: some View {
        Form {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
                    .listRowBackground(Color.clear)
                ThroughputChart(points: points,
                                ceilingMBps: identity.usbLink?.practicalCeilingMBps)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 14, trailing: 20))
                    .listRowBackground(Color.clear)
            }
            if let link = identity.usbLink { connection(link) }
            activity
            health
            if !displayVolumes.isEmpty { volumes }
            footnote
        }
        .formStyle(.grouped)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: identity.symbolName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(reading.isBusy ? Ink.read : .secondary)
                .symbolEffect(.pulse, isActive: reading.isBusy)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName)
                        .font(.title2.weight(.semibold))
                    Text(identity.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HeroMetric(bytesPerSecond: sample.totalBytesPerSecond,
                           caption: reading.isBusy ? "moving now" : "idle")

                HStack(spacing: 18) {
                    DirectionalRate(symbol: "arrow.down", label: "Read",
                                    bytesPerSecond: sample.readBytesPerSecond, tint: Ink.read)
                    DirectionalRate(symbol: "arrow.up", label: "Write",
                                    bytesPerSecond: sample.writeBytesPerSecond, tint: Ink.write)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func connection(_ link: USBLink) -> some View {
        Section("Connection") {
            LabeledContent("Link in use") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Format.mbps(currentMBps)) of ~\(Format.mbps(link.practicalCeilingMBps))")
                        .monospacedDigit()
                    Gauge(value: min(1, utilisation(of: link))) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(utilisation(of: link) > 0.8 ? Ink.healthy : Ink.read)
                        .frame(width: 130)
                }
            }
            ValueRow("Negotiated", link.lineRateLabel,
                     help: "The speed this drive and the port agreed on when it was plugged in. "
                         + "A drive capable of more will still run at this rate until it is "
                         + "reconnected somewhere faster.")
            ValueRow("Wire ceiling", Format.mbps(link.encodedCeilingMBps),
                     help: "What the link carries after encoding overhead. USB 3.0 spends 20% of "
                         + "the wire on 8b/10b encoding; USB 3.1 and later spend about 3%.")
            ValueRow("Transport", link.usesUASP ? "UASP" : "Bulk-only",
                     tint: link.usesUASP ? nil : Ink.write,
                     help: "UASP lets the drive queue several commands at once. Bulk-only "
                         + "transport handles one at a time and typically gives up about half "
                         + "the achievable speed on a fast link.")
            if link.isBottleneckedByHub {
                ValueRow("Through", link.hubsInPath.joined(separator: " → "))
            }

            if link.cappedByHub {
                Advice(level: .problem, symbol: "exclamationmark.triangle.fill",
                       message: "Capped at \(link.lineRateLabel) by a slower hop upstream. "
                              + "The drive itself negotiated faster than this — plug it "
                              + "straight into the Mac to get its full speed.")
            } else if link.bitsPerSecond == 480_000_000 {
                // Only high-speed. A 12 Mb/s full-speed device is full-speed by
                // design — telling its owner to change cables is nonsense.
                Advice(level: .warning, symbol: "bolt.trianglebadge.exclamationmark.fill",
                       message: "Running at \(link.generation). If this drive supports USB 3, "
                              + "the cable or the port is the limit — not the drive.")
            } else if !link.usesUASP {
                Advice(level: .warning, symbol: "tortoise.fill",
                       message: "This enclosure fell back to bulk-only transport, which usually "
                              + "costs about half the speed the link could carry.")
            } else if link.isBottleneckedByHub {
                Advice(level: .warning, symbol: "point.3.connected.trianglepath.dotted",
                       message: "Behind a hub. Its bandwidth is shared with everything else "
                              + "plugged into it.")
            }
        }
    }

    private var activity: some View {
        Section("Activity") {
            ValueRow("Read operations", Format.iops(sample.readOpsPerSecond) + "/s")
            ValueRow("Write operations", Format.iops(sample.writeOpsPerSecond) + "/s")
            ValueRow("Read latency", Format.latency(sample.readLatencyMicros))
            ValueRow("Write latency", Format.latency(sample.writeLatencyMicros))
            ValueRow("Queue depth", Format.queueDepth(sample.queueDepth),
                     help: "How many requests the drive was working on at once, on average. "
                         + "Rising queue depth is usually what is behind a latency spike.")
        }
    }

    private var activityIsHealthy: Bool {
        sample.readErrors == 0 && sample.writeErrors == 0 && sample.retries == 0
    }

    private var health: some View {
        Section("Health") {
            if activityIsHealthy {
                Label {
                    Text("No errors or retries since this drive was connected")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.healthy)
                }
            } else {
                ValueRow("Read errors", "\(sample.readErrors)",
                         tint: sample.readErrors > 0 ? Ink.problem : nil)
                ValueRow("Write errors", "\(sample.writeErrors)",
                         tint: sample.writeErrors > 0 ? Ink.problem : nil)
                ValueRow("Retries", "\(sample.retries)",
                         tint: sample.retries > 0 ? Ink.write : nil)
                Advice(level: .problem, symbol: "exclamationmark.triangle.fill",
                       message: "Errors and retries on a healthy drive should stay at zero. "
                              + "A cable, a port or the drive itself is failing.")
            }
        }
    }

    /// `/System/Volumes/Preboot`, `Recovery`, `xART` and `VM` are real mounts
    /// but mean nothing to someone looking for their USB stick.
    private var displayVolumes: [VolumeRef] {
        identity.volumes.filter {
            !$0.mountPath.hasPrefix("/System/Volumes/") || $0.mountPath == "/System/Volumes/Data"
        }
    }

    private var volumes: some View {
        Section("Volumes") {
            ForEach(displayVolumes) { volume in
                LabeledContent {
                    Text("\(Format.bytes(volume.freeBytes)) free")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(volume.name)
                            if volume.isBootVolume {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Gauge(value: usedFraction(volume)) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(usedFraction(volume) > 0.9 ? Ink.write : Ink.read)
                            .frame(width: 160)
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Section {
            Text("Shows device I/O at the block layer. Reads served from the system cache never "
                 + "reach the drive, so they will not appear here — and buffered writes can keep "
                 + "draining after a copy reports that it finished.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Maths

    private var currentMBps: Double { sample.totalBytesPerSecond / 1_000_000 }

    private func utilisation(of link: USBLink) -> Double {
        guard link.practicalCeilingMBps > 0 else { return 0 }
        return currentMBps / link.practicalCeilingMBps
    }

    private func usedFraction(_ volume: VolumeRef) -> Double {
        guard volume.totalBytes > 0 else { return 0 }
        return Double(volume.totalBytes - volume.freeBytes) / Double(volume.totalBytes)
    }
}
