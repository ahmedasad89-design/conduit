import SwiftUI

/// The menu bar title.
///
/// Fixed-width monospaced digits, and text only while something is actually
/// moving. A status item that resizes on every digit shoves everything to its
/// right along the menu bar, which is the kind of small wrongness that makes an
/// app feel unfinished.
struct MenuBarLabel: View {
    var text: String
    var deviceCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: deviceCount > 0 ? "externaldrive.fill" : "externaldrive")
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}

/// Modelled on a Control Center module: one compact block per drive and a quiet
/// footer of actions.
///
/// Deliberately no `glassEffect` here. `MenuBarExtra(.window)` keeps its content
/// view alive even while the panel is closed, so the blur ran continuously for a
/// panel nobody was looking at — a profile showed `vSepConvolveARGB8bgf_vec`,
/// the blur convolution, as the single largest consumer in the whole process.
/// macOS already gives a menu bar window its own vibrant material, so the glass
/// was redundant as well as expensive.
///
/// The per-device `Chart` below is fine and stays: measured at 0.13% against
/// 0.16% idle with it removed, which is noise.
struct MenuBarPanel: View {
    @Bindable var store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.usbDevices.isEmpty && store.externalDevices.isEmpty {
                ContentUnavailableView {
                    Label("No External Drives", systemImage: "externaldrive")
                } description: {
                    Text("Connect a drive to see its speed here.")
                }
                .frame(height: 150)
            } else {
                ForEach(Array(modules.enumerated()), id: \.element.identity.id) { index, reading in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    module(for: reading)
                }
            }

            Divider().padding(.top, 6)

            HStack(spacing: 12) {
                Button("Open Conduit") { openWindow(id: "main") }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Conduit")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var modules: [DeviceReading] {
        store.usbDevices + store.externalDevices
    }

    private func module(for reading: DeviceReading) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: reading.identity.symbolName)
                    .foregroundStyle(reading.sample.isActive ? Ink.read : .secondary)
                Text(reading.identity.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let link = reading.identity.usbLink {
                    Text(link.lineRateLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                DirectionalRate(symbol: "arrow.down", label: "Read",
                                bytesPerSecond: reading.sample.readBytesPerSecond, tint: Ink.read)
                DirectionalRate(symbol: "arrow.up", label: "Write",
                                bytesPerSecond: reading.sample.writeBytesPerSecond, tint: Ink.write)
            }

            ThroughputChart(points: store.history(for: reading.identity.id),
                            ceilingMBps: reading.identity.usbLink?.practicalCeilingMBps,
                            height: 54)
        }
        .padding(.vertical, 4)
    }
}
