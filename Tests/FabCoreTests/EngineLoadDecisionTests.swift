import FabCore
import Testing

@Suite("EngineLoadDecision")
struct EngineLoadDecisionTests {
    @Test func appliesOnlyWhenIdleOrFailed() {
        #expect(EngineLoadDecision.shouldApply(isIdle: true, isFailed: false))
        #expect(EngineLoadDecision.shouldApply(isIdle: false, isFailed: true))
        #expect(!EngineLoadDecision.shouldApply(isIdle: false, isFailed: false))
    }

    @Test func nonWhisperEngineRevertsToWhisperAndReloads() {
        let r = EngineLoadDecision.fallback(after: .parakeet)
        #expect(r.revertTo == .whisper)
        #expect(r.reloadWhisper)
        let r2 = EngineLoadDecision.fallback(after: .appleSpeech)
        #expect(r2.revertTo == .whisper)
        #expect(r2.reloadWhisper)
    }

    @Test func whisperFailureDoesNotReloadItself() {
        let r = EngineLoadDecision.fallback(after: .whisper)
        #expect(r.revertTo == .whisper)
        #expect(!r.reloadWhisper)
    }
}
