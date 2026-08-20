import SwiftUI

/// ⌘, — the shortcut every Mac app is expected to answer.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    @StateObject private var loginItem = Local(false)
    @StateObject private var loginFailure = Local<String?>(nil)

    /// A binding whose setter is the *only* thing that can register or
    /// unregister the login item.
    ///
    /// This was an `@StateObject` value plus `.onChange`, which cannot tell a
    /// user's tap from the code's own write. Seeding the switch on appear fired
    /// the handler and silently called `register()`; the handler's own
    /// snap-back then re-entered it and called `unregister()`. A single tap
    /// produced `[register(), unregister()]`, the switch flipped itself off,
    /// and the error message was cleared by the re-entrant pass before it could
    /// be read. A binding has no such ambiguity: nothing writes it but the user.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.value },
            set: { wanted in
                loginFailure.value = prefs.setLaunchAtLogin(wanted)
                // Show what macOS actually decided, not what was asked for.
                loginItem.value = prefs.launchesAtLogin
            }
        )
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: launchAtLogin)
                if let failure = loginFailure.value {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(Ink.problem)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Menu bar only", isOn: $prefs.menuBarOnly)
                Text("Hides the Dock icon. Conduit stays available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show internal drive", isOn: $prefs.showInternalDrives)
            }

            Section("Notifications") {
                Toggle("When a drive connects on a slow link", isOn: $prefs.notifyOnConnect)
                Text("Tells you at the moment you plug in — before you start a long copy — if a "
                     + "drive negotiated a slower link than it is capable of, fell back to "
                     + "bulk-only transport, or is sharing a hub. Nothing is sent when the "
                     + "connection is healthy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("When a drive reports errors", isOn: $prefs.notifyOnErrors)
                Text("Read or write errors on a healthy drive should stay at zero. "
                     + "Reported once per drive per session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Measurement") {
                Toggle("Slow down when nothing is happening", isOn: $prefs.adaptiveSampling)
                    .onChange(of: prefs.adaptiveSampling) { _, _ in
                        MonitorStore.shared.applyAdaptiveSamplingPreference()
                    }
                Text("Samples four times a second during a transfer and once a second when idle. "
                     + "Turning this off keeps the full rate at all times, which costs a little "
                     + "more battery for slightly finer detail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 470)
        // Seeds the switch without going through the binding's setter, so
        // appearing on screen cannot itself change the login item.
        .task { loginItem.value = prefs.launchesAtLogin }
    }
}
