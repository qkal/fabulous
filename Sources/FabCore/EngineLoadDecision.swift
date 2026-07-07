import Foundation

/// Policy for applying and recovering from transcription-engine changes.
public enum EngineLoadDecision {
    /// An engine-preference change takes effect only between utterances; a
    /// mid-recording/loading swap would corrupt the dictation state machine.
    public static func shouldApply(isIdle: Bool, isFailed: Bool) -> Bool {
        isIdle || isFailed
    }

    /// When an engine fails to load, dictation must keep working: revert to
    /// Whisper. Reverting the *preference* alone no-ops (it fires while state
    /// isn't idle/failed), so a non-Whisper failure must also reload Whisper.
    public static func fallback(after engine: TranscriptionEngineKind)
        -> (revertTo: TranscriptionEngineKind, reloadWhisper: Bool) {
        engine == .whisper ? (.whisper, false) : (.whisper, true)
    }
}
