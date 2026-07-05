/// Batch-path biasing seam, adopted only by backends whose engine takes
/// contextual vocabulary (today: SpeechAnalyzer). AppController applies
/// it via `as?` before the batch transcribe, so `TranscriptionBackend`
/// and the Whisper/Parakeet backends stay untouched. Terms are
/// per-dictation: stored here, consumed (and cleared) by the next
/// `transcribe` call.
public protocol ContextBiasing: Sendable {
    func setContextualTerms(_ terms: [String]) async
}
