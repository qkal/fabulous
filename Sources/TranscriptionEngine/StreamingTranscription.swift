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
    /// full string per update. Finishes when the session ends.
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
/// session survived, otherwise run the batch path — a transcript is never
/// silently lost.
public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool) {
        if let session {
            do {
                return (try await session.finish(), true)
            } catch {
                await session.cancel()
                // Fall through to batch; the caller still has the full buffer.
            }
        }
        return (try await fallback(), false)
    }
}
