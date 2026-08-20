import Foundation
import DiskArbitration

/// The only state a DiskArbitration C callback is allowed to touch.
///
/// `@convention(c)` callbacks cannot capture context, so DiskArbitration hands
/// back a raw pointer instead. Pointing it at the watcher itself would mean
/// smuggling a mutable, main-actor-isolated object into a background queue.
/// Pointing it at this box does not: every stored property is immutable and
/// Sendable, so it is genuinely safe to share, with no unchecked escape hatch.
private final class ChangeSignal: Sendable {
    let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// Watches for volumes mounting, unmounting and changing, so the sampler can
/// refresh its topology the instant something happens rather than waiting for
/// its next scheduled re-walk.
@MainActor
final class DiskWatcher {

    /// Fires once per relevant DiskArbitration event. Coalescing is the
    /// consumer's business — `bufferingNewest(1)` means a burst of events
    /// during a multi-volume mount collapses into a single wake-up.
    nonisolated let changes: AsyncStream<Void>
    private nonisolated let continuation: AsyncStream<Void>.Continuation

    private let queue = DispatchQueue(label: "com.ahmed.conduit.diskarb", qos: .utility)
    private var session: DASession?
    /// Retained for as long as callbacks are registered: the session holds only
    /// an unmanaged pointer to it.
    private var signal: ChangeSignal?

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.changes = stream
        self.continuation = continuation
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let signal = ChangeSignal(continuation)
        self.signal = signal
        let context = Unmanaged.passUnretained(signal).toOpaque()

        DARegisterDiskAppearedCallback(session, nil, conduitDiskAppeared, context)
        DARegisterDiskDisappearedCallback(session, nil, conduitDiskDisappeared, context)

        // Mounting an already-attached disk is a description change, not an
        // appearance. Without this, plugging a drive in and then mounting it
        // from Disk Utility would not refresh the volume list promptly.
        DARegisterDiskDescriptionChangedCallback(session, nil, nil,
                                                 conduitDiskDescriptionChanged, context)

        // Dispatch queue, never `DASessionScheduleWithRunLoop`: run-loop
        // delivery is mode-scoped, and a menu bar app's main loop enters
        // event-tracking mode whenever the menu is open — at which point the
        // session would silently stop delivering.
        DASessionSetDispatchQueue(session, queue)
    }

    /// Unscheduling the session stops delivery, and releasing it tears down the
    /// registrations with it. There is no need to unregister each callback
    /// individually — and doing so would mean round-tripping C function
    /// pointers through `unsafeBitCast`, which is not worth the risk here.
    func stop() {
        guard let session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        // Unscheduling stops *new* deliveries; it is not a barrier against a
        // callback already running on the queue. Dropping the last reference to
        // the box while one is mid-flight is a use-after-free, so wait for the
        // queue to drain first.
        queue.sync {}
        self.signal = nil
    }

    deinit { continuation.finish() }
}

// MARK: - C callbacks
//
// These live at file scope, not inside `DiskWatcher`, and that is load-bearing.
// A closure written inside a `@MainActor` type inherits that isolation, and
// Swift 6 then emits an executor assertion into it. DiskArbitration calls back
// on its own dispatch queue, so the assertion trips and the process takes a
// SIGTRAP the first time a disk is reported — which is immediately, because the
// session replays every already-attached disk on registration.
//
// At file scope they are genuinely nonisolated, which is the truth: all they do
// is poke a Sendable continuation.

private func signalChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<ChangeSignal>.fromOpaque(context)
        .takeUnretainedValue()
        .continuation.yield(())
}

private let conduitDiskAppeared: DADiskAppearedCallback = { _, context in
    signalChange(context)
}

private let conduitDiskDisappeared: DADiskDisappearedCallback = { _, context in
    signalChange(context)
}

private let conduitDiskDescriptionChanged: DADiskDescriptionChangedCallback = { _, _, context in
    signalChange(context)
}
