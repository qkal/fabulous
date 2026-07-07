import Foundation

/// What to do with a dictation's final text once processing is done.
public enum TerminalDelivery: Equatable, Sendable {
    /// Non-empty text → hand to the injector.
    case inject
    /// Non-empty text that can't be injected → clipboard + overlay notice.
    case safetyNet(String)
    /// Legitimately empty (true scratch-that, or nothing was said).
    case dropSilently
}

/// Guarantees the "a transcript is never silently lost" invariant at the
/// finish-recording seam: any speech that survived to `cleanedText` but was
/// then emptied by deterministic post-processing is safety-netted, not dropped.
public enum TerminalDeliveryDecision {
    public static func decide(finalText: String, cleanedText: String) -> TerminalDelivery {
        if !finalText.isEmpty { return .inject }
        if !cleanedText.isEmpty { return .safetyNet(cleanedText) }
        return .dropSilently
    }
}
