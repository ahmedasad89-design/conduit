import Testing
@testable import Conduit

/// These pin the three rules that hold idle CPU at 0.5%. Each is individually
/// easy to break and individually invisible when broken — the app still works,
/// it just quietly costs ten times more.
@Suite("PublishGate")
struct PublishGateTests {

    @Test("publishes on every second tick at the default cadence")
    func halfRate() {
        var gate = PublishGate(publishEvery: 2, idleTicksBeforeFreeze: 240)
        let published = (1...8).map { _ in
            gate.advance(anyActive: true, structuralChange: false).publish
        }
        #expect(published == [false, true, false, true, false, true, false, true])
    }

    @Test("a structural change publishes immediately, whatever the cadence")
    func structuralChangeJumpsTheQueue() {
        var gate = PublishGate(publishEvery: 4, idleTicksBeforeFreeze: 240)
        // Tick 1 would not normally publish under a 4-tick cadence.
        #expect(gate.advance(anyActive: false, structuralChange: true).publish)
        #expect(gate.tick == 1)
    }

    @Test("history keeps accumulating while anything is active")
    func activeKeepsGraphAlive() {
        var gate = PublishGate(publishEvery: 2, idleTicksBeforeFreeze: 4)
        for _ in 1...20 {
            #expect(gate.advance(anyActive: true, structuralChange: false).accumulateHistory)
        }
    }

    @Test("history freezes only once the whole window is zero, not on first idle tick")
    func freezesAfterWindowClears() {
        var gate = PublishGate(publishEvery: 2, idleTicksBeforeFreeze: 4)
        _ = gate.advance(anyActive: true, structuralChange: false)   // tick 1, active

        // The next four ticks are idle but the spike is still on screen.
        for _ in 0..<4 {
            #expect(gate.advance(anyActive: false, structuralChange: false).accumulateHistory)
        }
        // Now the spike has scrolled off and every visible point is zero.
        #expect(gate.advance(anyActive: false, structuralChange: false).accumulateHistory == false)
    }

    @Test("activity after a freeze thaws the graph again")
    func activityThaws() {
        var gate = PublishGate(publishEvery: 2, idleTicksBeforeFreeze: 2)
        for _ in 0..<10 { _ = gate.advance(anyActive: false, structuralChange: false) }
        #expect(gate.advance(anyActive: false, structuralChange: false).accumulateHistory == false)
        #expect(gate.advance(anyActive: true, structuralChange: false).accumulateHistory)
    }

    @Test("a degenerate cadence still publishes every tick rather than never")
    func cadenceFloor() {
        var gate = PublishGate(publishEvery: 0, idleTicksBeforeFreeze: 0)
        #expect(gate.advance(anyActive: false, structuralChange: false).publish)
        #expect(gate.advance(anyActive: false, structuralChange: false).publish)
    }
}
