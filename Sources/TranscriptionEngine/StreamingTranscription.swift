import FabCore
import Foundation

/// A live transcription session for one utterance: audio is fed in chunks
/// while the user is still speaking, so most decoding overlaps recording
/// and `finish()` is just the finalize wait.
public protocol StreamingSession: Sendable {
    /// Appends 16 kHz mono Float32 samples captured since the last feed.
    /// Calls arriving after `finish()`/`cancel()` began are ignored — the
    /// feed timer races the stop path by design.
    func feed(_ samples: [Float]) async

    /// Best transcript so far (finalized pieces + volatile tail), a fresh
    /// full string per update. Finishes when the session ends. Single
    /// consumer only — `AsyncStream` does not fan out; a second `for await`
    /// loop silently starves the first.
    var partials: AsyncStream<String> { get }

    /// Signals end of audio and waits for the final decode.
    func finish() async throws -> Transcript

    /// Abandons the session. Safe to call at any time, including after
    /// `finish()` failed.
    func cancel() async
}

/// A backend that can transcribe live during recording. `AppController`
/// detects capability with a runtime conformance check; WhisperKit stays
/// batch-only.
public protocol StreamingTranscriptionBackend: TranscriptionBackend {
    /// Opens a session for one utterance. Throws if the engine isn't ready
    /// (e.g. `load` hasn't succeeded).
    func startStreamingSession() async throws -> any StreamingSession
}

/// The fallback invariant in one place: use the streaming result when the
/// session survived and produced text, otherwise run the batch path — a
/// transcript is never silently lost. If `finish()` succeeds but returns
/// empty text, we still fall back (defense-in-depth): genuine silence costs
/// one extra batch pass that also returns empty, while a swallowed utterance
/// gets rescued. No `cancel()` is needed there — `finish()` already succeeded.
public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool) {
        if let session {
            do {
                let transcript = try await session.finish()
                if !transcript.text.isEmpty {
                    return (transcript, true)
                }
                // Empty streamed text: fall through to batch (no cancel —
                // finish succeeded). The caller still has the full buffer.
            } catch {
                await session.cancel()
                // Fall through to batch; the caller still has the full buffer.
            }
        }
        return (try await fallback(), false)
    }
}
