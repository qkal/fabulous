import FabCore
import Testing

@Suite("TerminalDeliveryDecision")
struct TerminalDeliveryDecisionTests {
    @Test func nonEmptyFinalTextInjects() {
        #expect(TerminalDeliveryDecision.decide(finalText: "hello", cleanedText: "hello") == .inject)
    }

    @Test func postProcessorSwallowedTextIsSafetyNetted() {
        // cleaned had speech, final is empty → deterministic post-processing ate it.
        #expect(TerminalDeliveryDecision.decide(finalText: "", cleanedText: "hello world")
            == .safetyNet("hello world"))
    }

    @Test func legitimatelyEmptyDropsSilently() {
        // LLM emptied it (scratch-that policy) or nothing was ever said.
        #expect(TerminalDeliveryDecision.decide(finalText: "", cleanedText: "") == .dropSilently)
    }
}
