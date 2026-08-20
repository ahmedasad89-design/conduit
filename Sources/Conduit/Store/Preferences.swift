import Foundation
import Observation
import ServiceManagement
import AppKit

/// User-facing settings, backed by `UserDefaults`.
///
/// Deliberately small. Every one of these earns its place by changing something
/// a person actually notices; a preference nobody sets is a maintenance cost
/// with a UI attached.
@MainActor
@Observable
final class Preferences {

    static let shared = Preferences()

    private enum Key {
        static let showInternal = "showInternalDrives"
        static let notifyOnConnect = "notifyOnConnect"
        static let notifyOnErrors = "notifyOnErrors"
        static let menuBarOnly = "menuBarOnly"
        static let adaptiveSampling = "adaptiveSampling"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.notifyOnConnect: true,
            Key.notifyOnErrors: true,
            Key.adaptiveSampling: true
        ])
        showInternalDrives = defaults.bool(forKey: Key.showInternal)
        notifyOnConnect = defaults.bool(forKey: Key.notifyOnConnect)
        notifyOnErrors = defaults.bool(forKey: Key.notifyOnErrors)
        menuBarOnly = defaults.bool(forKey: Key.menuBarOnly)
        adaptiveSampling = defaults.bool(forKey: Key.adaptiveSampling)
    }

    var showInternalDrives: Bool {
        didSet { defaults.set(showInternalDrives, forKey: Key.showInternal) }
    }

    /// The app's most distinctive behaviour: say something at the moment a
    /// drive connects on a worse link than it is capable of.
    var notifyOnConnect: Bool {
        didSet { defaults.set(notifyOnConnect, forKey: Key.notifyOnConnect) }
    }

    var notifyOnErrors: Bool {
        didSet { defaults.set(notifyOnErrors, forKey: Key.notifyOnErrors) }
    }

    var menuBarOnly: Bool {
        didSet {
            defaults.set(menuBarOnly, forKey: Key.menuBarOnly)
            applyActivationPolicy()
        }
    }

    var adaptiveSampling: Bool {
        didSet { defaults.set(adaptiveSampling, forKey: Key.adaptiveSampling) }
    }

    /// Hides the Dock icon without a separate helper bundle.
    ///
    /// `NSApplication.shared`, not `NSApp`. `NSApp` is nil until the app has
    /// finished starting up, and the optional chain swallowed that silently —
    /// so calling this from `App.init()` did nothing at all and the preference
    /// only took effect in the session it was toggled in. This version cannot
    /// fail quietly.
    func applyActivationPolicy() {
        NSApplication.shared.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }

    // MARK: - Launch at login

    /// `SMAppService.mainApp` needs no helper bundle and works for an
    /// unsandboxed, ad-hoc-signed app — the registration is by bundle
    /// identifier, not by signature.
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Returns: a message to show if the request could not be satisfied.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The usual cause is the user having denied the login item in
            // System Settings, which the app cannot override.
            return "macOS refused the change: \(error.localizedDescription)"
        }
    }
}
