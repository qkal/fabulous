import FabCore
import Testing

@Suite("RecordingGate")
struct RecordingGateTests {
    @Test func normalPushToTalkCycle() {
        var g = RecordingGate()
        #expect(g.handle(.press, mode: .pushToTalk) == .beginStart)
        #expect(g.handle(.startSucceeded, mode: .pushToTalk) == .goLive)
        #expect(g.phase == .recording)
        #expect(g.handle(.release, mode: .pushToTalk) == .finish)
        #expect(g.phase == .finishing)
        #expect(g.handle(.finished, mode: .pushToTalk) == .none)
        #expect(g.phase == .idle)
    }

    @Test func fastTapReleaseDuringStartStillFinishes() {
        // D3: release arrives while recorder.start() is still in flight.
        var g = RecordingGate()
        #expect(g.handle(.press, mode: .pushToTalk) == .beginStart)   // .starting
        #expect(g.handle(.release, mode: .pushToTalk) == .none)       // stop deferred
        #expect(g.phase == .starting)
        #expect(g.handle(.startSucceeded, mode: .pushToTalk) == .finish)  // not stuck
        #expect(g.phase == .finishing)
    }

    @Test func startFailureReturnsToIdle() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        #expect(g.handle(.startFailed, mode: .pushToTalk) == .abortToIdle)
        #expect(g.phase == .idle)
    }

    @Test func toggleDoubleFinishOnlyFiresOnce() {
        // D4: two quick toggle presses must not double-finish.
        var g = RecordingGate()
        _ = g.handle(.press, mode: .toggle)              // .starting
        _ = g.handle(.startSucceeded, mode: .toggle)     // .recording
        #expect(g.handle(.press, mode: .toggle) == .finish)   // .finishing
        #expect(g.handle(.press, mode: .toggle) == .none)     // ignored
    }

    @Test func toggleOffBeforeItStartedStillFinishes() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .toggle)              // .starting
        #expect(g.handle(.press, mode: .toggle) == .none)     // toggle-off deferred
        #expect(g.handle(.startSucceeded, mode: .toggle) == .finish)
    }

    @Test func repeatedPushToTalkPressWhileStartingIsIgnored() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        #expect(g.handle(.press, mode: .pushToTalk) == .none)
        #expect(g.phase == .starting)
    }

    @Test func finishedResetsFromAnyPhase() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        _ = g.handle(.startSucceeded, mode: .pushToTalk)  // .recording
        #expect(g.handle(.finished, mode: .pushToTalk) == .none)  // e.g. Esc-cancel
        #expect(g.phase == .idle)
    }
}
