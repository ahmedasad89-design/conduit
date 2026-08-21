import SwiftUI

struct MainWindow: View {
    @Bindable var store: MonitorStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            Group {
                if let selected = store.selected {
                    DeviceDetailView(reading: selected,
                                     points: store.history(for: selected.identity.id))
                        .equatable()
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 580, minHeight: 480)
            .navigationTitle(store.selected?.identity.displayName ?? "Conduit")
            .navigationSubtitle(store.selected?.identity.subtitle ?? "")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.beginSpeedTest()
                    } label: {
                        Label("Speed Test", systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .help("Measure this drive by writing and reading a temporary file")
                    .disabled(store.benchmarkTargets.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let identity = store.selected?.identity { store.eject(identity) }
                    } label: {
                        Label("Eject", systemImage: "eject")
                    }
                    .help("Unmount and eject this drive")
                    .disabled(store.selected?.identity.isEjectable != true)
                }
            }
        }
        .sheet(isPresented: $store.showingSpeedTest) {
            SpeedTestSheet(store: store)
        }
        // The dissenter's own words are almost always the useful ones — most
        // often naming the application still holding a file open.
        .alert("Could not eject",
               isPresented: Binding(get: { store.ejectFailure != nil },
                                    set: { if !$0 { store.ejectFailure = nil } })) {
            Button("OK", role: .cancel) { store.ejectFailure = nil }
        } message: {
            Text(store.ejectFailure ?? "")
        }
    }

    // MARK: - Sidebar

    /// A real source list: sections, no custom cards, and a live trace on the
    /// right of a row only while that device is actually moving data.
    private var sidebar: some View {
        List(selection: $store.selectedDeviceID) {
            if !store.usbDevices.isEmpty {
                Section("USB") {
                    ForEach(store.usbDevices, id: \.identity.id) { reading in
                        DeviceRow(reading: reading, points: store.history(for: reading.identity.id))
                            .equatable()
                            .tag(reading.identity.id)
                    }
                }
            }
            if !store.externalDevices.isEmpty {
                Section("Other External") {
                    ForEach(store.externalDevices, id: \.identity.id) { reading in
                        DeviceRow(reading: reading, points: store.history(for: reading.identity.id))
                            .equatable()
                            .tag(reading.identity.id)
                    }
                }
            }
            if store.showInternalDrives && !store.internalDevices.isEmpty {
                Section("Internal") {
                    ForEach(store.internalDevices, id: \.identity.id) { reading in
                        DeviceRow(reading: reading, points: store.history(for: reading.identity.id))
                            .equatable()
                            .tag(reading.identity.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // A VStack, not two loose siblings: sibling views in a
            // `safeAreaInset` builder form a TupleView and are laid out on top
            // of one another, which drew the divider through the middle of the
            // toggle.
            VStack(spacing: 0) {
                Divider()
                Toggle("Show internal drive", isOn: $store.showInternalDrives)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No External Drives", systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(store.showInternalDrives
                 ? "Connect a drive and it will appear here immediately."
                 : "Connect a drive, or switch on “Show internal drive” to watch this Mac's own SSD.")
        }
    }
}

struct DeviceRow: View, Equatable {
    var reading: DeviceReading
    var points: [GraphPoint]

    private var identity: DeviceIdentity { reading.identity }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: identity.symbolName)
                .foregroundStyle(reading.isBusy ? Ink.read : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(identity.displayName)
                    .lineLimit(1)
                Text(identity.usbLink?.lineRateLabel ?? identity.interconnect.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if reading.isBusy {
                Sparkline(points: points, tint: Ink.read)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: reading.isBusy)
    }
}
