import Foundation

/// What to do with a delivered transcript's persistence + clipboard, decided
/// AFTER delivery (unlike TerminalDeliveryDecision, which runs pre-deliver).
public enum HistoryPersistence: Equatable, Sendable {
    /// Record history + set lastTranscript + leave the safety-net clipboard
    /// copy (if any) persistent and unmarked. The default for every path.
    case persist
    /// AX-confirmed password field: no history, no lastTranscript, and the
    /// clipboard copy must be concealed + timed-cleared.
    case concealSkip
}

public enum HistoryPersistenceDecision {
    public static func decide(outcome: DeliveryOutcome) -> HistoryPersistence {
        if outcome.refusal == .secureInputActive, outcome.confirmedSecureField {
            return .concealSkip
        }
        return .persist
    }
}
