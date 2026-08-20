import Foundation

/// Decides, for each sampler tick, whether the graph should grow and whether
/// SwiftUI should be handed new state.
///
/// This exists as its own type because it is the load-bearing reason the app
/// costs 0.5% of a core at idle instead of 6%, and because those savings come
/// from three rules that are individually easy to break and individually
/// invisible when broken:
///
/// - Sample at 4 Hz but publish at 2 Hz. Redrawing a 240-point two-series chart
///   is the most expensive thing the app does and nobody can perceive the
///   difference. History still accumulates at the full rate, so no spike is lost.
/// - Stop growing the graph once every point in the visible window is zero.
///   A frozen flat line and a scrolling flat line are indistinguishable.
/// - Never delay a structural change. A drive appearing or disappearing must
///   reach the UI on the tick it happens, whatever the cadence says.
struct PublishGate {

    struct Decision: Equatable {
        /// Append a point to the rolling history this tick.
        var accumulateHistory: Bool
        /// Hand the observable collections to SwiftUI this tick.
        var publish: Bool
    }

    /// Publish every Nth tick. 2 at a 4 Hz sample rate gives a 2 Hz UI.
    let publishEvery: Int
    /// How many consecutive all-zero ticks before the graph is considered
    /// entirely empty. Matches the history window length, so the gate closes
    /// exactly when the last non-zero point scrolls off.
    let idleTicksBeforeFreeze: Int

    private(set) var tick = 0
    private var lastActiveTick = 0

    init(publishEvery: Int = 2, idleTicksBeforeFreeze: Int = 240) {
        self.publishEvery = max(1, publishEvery)
        self.idleTicksBeforeFreeze = max(1, idleTicksBeforeFreeze)
    }

    /// - Parameters:
    ///   - anyActive: any device moved bytes this tick.
    ///   - structuralChange: a device appeared or disappeared.
    mutating func advance(anyActive: Bool, structuralChange: Bool) -> Decision {
        tick += 1
        if anyActive { lastActiveTick = tick }

        let everythingOnScreenIsZero = tick - lastActiveTick > idleTicksBeforeFreeze
        return Decision(
            accumulateHistory: !everythingOnScreenIsZero,
            publish: structuralChange || tick % publishEvery == 0
        )
    }
}
