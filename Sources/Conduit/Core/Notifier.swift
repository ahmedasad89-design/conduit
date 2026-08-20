import Foundation
import UserNotifications

/// Speaks up at the one moment the user can still do something about it.
///
/// This is the app's sharpest edge over every other disk utility. Conduit
/// already knows, the instant a drive mounts, that it negotiated 480 Mb/s when
/// it is capable of 5 Gb/s, or that it fell back to bulk-only transport, or
/// that it is sharing a hub. That knowledge is worth nothing sitting in a
/// window nobody has open — the moment it matters is right before someone
/// starts a forty-minute copy.
@MainActor
final class Notifier {

    static let shared = Notifier()

    private var authorised = false
    private var askedForPermission = false
    private var authorisationInFlight: Task<Bool, Never>?
    /// Errors are reported once per drive per session; a failing cable would
    /// otherwise produce a notification every quarter second.
    private var reportedErrors: Set<UInt64> = []

    /// Asks only when there is something worth saying, so the prompt arrives
    /// with obvious context rather than at launch out of nowhere.
    private func ensureAuthorised() async -> Bool {
        if authorised { return true }
        // Two drives connecting together used to race: the second call saw
        // `askedForPermission` already set and gave up, silently dropping its
        // notification. Callers now await the same request.
        if let inFlight = authorisationInFlight { return await inFlight.value }
        if askedForPermission { return false }
        askedForPermission = true

        let request = Task { () -> Bool in
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorisationInFlight = request
        let granted = await request.value
        authorisationInFlight = nil
        authorised = granted
        return granted
    }

    @discardableResult
    private func post(title: String, body: String, id: String) async -> Bool {
        guard await ensureAuthorised() else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    /// - Returns: the diagnosis shown to the user, or `nil` when the drive
    ///   connected in good health and deserves silence.
    static func connectionDiagnosis(for identity: DeviceIdentity) -> String? {
        guard let link = identity.usbLink else { return nil }

        if link.cappedByHub {
            return "Connected at \(link.lineRateLabel), capped by a slower hub upstream. "
                 + "Plugging it straight into the Mac would be faster."
        }
        if link.bitsPerSecond == 480_000_000 {
            return "Connected at \(link.generation) — about "
                 + "\(Format.mbps(link.practicalCeilingMBps)) at best. "
                 + "If this drive supports USB 3, try another port or cable."
        }
        // Below high-speed there is nothing to advise: a full-speed or
        // low-speed device is that by design, not by misconfiguration.
        if link.bitsPerSecond < 480_000_000 { return nil }
        if !link.usesUASP {
            return "Connected at \(link.lineRateLabel) but using bulk-only transport, "
                 + "which typically costs about half the achievable speed."
        }
        if link.isBottleneckedByHub {
            return "Connected at \(link.lineRateLabel) through a hub. Its bandwidth is "
                 + "shared with everything else plugged into that hub."
        }
        return nil
    }

    func deviceConnected(_ identity: DeviceIdentity) async {
        guard Preferences.shared.notifyOnConnect,
              let diagnosis = Self.connectionDiagnosis(for: identity) else { return }
        await post(title: identity.displayName,
                   body: diagnosis,
                   id: "connect-\(identity.id)")
    }

    /// A handful of retries over a drive's lifetime is normal on USB. Only a
    /// real error, or retries well past the noise floor, is worth interrupting
    /// someone for — and the wording says "worth checking", not "your drive is
    /// dying", because retries alone do not prove that.
    private static let retryNoiseFloor: Int64 = 20

    func errorsDetected(on identity: DeviceIdentity, errors: Int64, retries: Int64) async {
        guard Preferences.shared.notifyOnErrors,
              errors > 0 || retries > Self.retryNoiseFloor,
              !reportedErrors.contains(identity.id) else { return }

        let detail = errors > 0
            ? "\(errors) I/O error\(errors == 1 ? "" : "s")"
            : "\(retries) retries"
        // Only mark it reported once it has actually gone out, so a failed or
        // unauthorised post does not silence the drive for the whole session.
        let posted = await post(
            title: "\(identity.displayName) is reporting problems",
            body: "\(detail) since it was connected. Worth checking the cable and the port — "
                + "these normally stay at zero.",
            id: "errors-\(identity.id)"
        )
        if posted { reportedErrors.insert(identity.id) }
    }

    func forget(deviceID: UInt64) {
        reportedErrors.remove(deviceID)
    }
}
