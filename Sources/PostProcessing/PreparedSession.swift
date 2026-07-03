/// Holds at most one prewarmed model session keyed by its instructions.
/// `take` always clears the slot — matched or not — so a prepared session
/// can serve at most one dictation. That is the fresh-session-per-dictation
/// invariant (no context accumulation, no text leaking across dictations)
/// enforced by construction. Generic so tests cover the consume-once
/// semantics without FoundationModels.
struct PreparedSession<Session> {
    private var stored: (instructions: String, session: Session)?

    mutating func store(_ session: Session, instructions: String) {
        stored = (instructions, session)
    }

    /// Returns the session only when `instructions` match what it was
    /// prepared with; either way the slot is emptied.
    mutating func take(matching instructions: String) -> Session? {
        defer { stored = nil }
        guard let stored, stored.instructions == instructions else { return nil }
        return stored.session
    }
}
