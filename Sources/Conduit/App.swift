import SwiftUI

@main
struct ConduitApp: App {
    /// See `MonitorStore.shared` — `@State` is unavailable in a Command Line
    /// Tools build of the macOS 27 SDK.
    private var store: MonitorStore { MonitorStore.shared }
    private var prefs: Preferences { Preferences.shared }

    init() {
        // Monitoring starts with the app, not with a window.
        //
        // This used to hang off the main window's `.task`, which meant that on
        // any launch where macOS restored the window as closed — the normal
        // state for a menu bar app — the sampler never started and the menu bar
        // sat at zero forever. A menu bar app's engine cannot depend on a
        // window being on screen.
        MainActor.assumeIsolated {
            MonitorStore.shared.start()
            // Deferred by one turn of the run loop: NSApplication is not set up
            // during `App.init()`, and setting the activation policy there is a
            // no-op.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Preferences.shared.applyActivationPolicy() }
            }
        }
    }

    var body: some Scene {
        Window("Conduit", id: "main") {
            MainWindow(store: store)
        }
        .defaultSize(width: 1000, height: 720)
        // A `Window` scene deliberately does not come back once the user has
        // closed it, and that state survives relaunch. For an app whose whole
        // point is a window you open occasionally, that reads as "the app is
        // broken" — it launches, puts an item in the menu bar, and shows
        // nothing. Launch presented; the menu bar item is still there for
        // anyone who wants it out of the way.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra {
            MenuBarPanel(store: store)
        } label: {
            MenuBarLabel(text: store.menuBarText, deviceCount: store.usbDeviceCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(prefs: prefs)
        }
    }
}
