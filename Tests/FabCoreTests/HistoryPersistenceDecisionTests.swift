import FabCore
import Testing

@Suite("HistoryPersistenceDecision")
struct HistoryPersistenceDecisionTests {
    private func outcome(_ r: DeliveryRefusal?, secure: Bool) -> DeliveryOutcome {
        DeliveryOutcome(method: r == nil ? .paste : .safetyNet, refusal: r, confirmedSecureField: secure)
    }

    @Test func injectedTranscriptIsPersisted() {
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(nil, secure: false)) == .persist)
    }

    @Test func confirmedSecureFieldIsConcealedAndSkipped() {
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(.secureInputActive, secure: true)) == .concealSkip)
    }

    @Test func globalSecureInputOnNonPasswordFieldStillPersists() {
        // IsSecureEventInputEnabled() is process-global; a non-secure focused
        // field means this is a legit transcript — record it normally.
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(.secureInputActive, secure: false)) == .persist)
    }

    @Test func focusChangeAndAccessibilityStillPersist() {
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(.focusChanged, secure: false)) == .persist)
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(.accessibilityNotGranted, secure: false)) == .persist)
        #expect(HistoryPersistenceDecision.decide(outcome: outcome(.allStrategiesFailed, secure: false)) == .persist)
    }
}
