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

    /// Attaches contextual vocabulary (e.g. on-screen terms) to a session
    /// already in flight. Best-effort and engine-dependent: the default
    /// no-op covers engines without a biasing API. Never throws — a
    /// rejected context is logged and the session continues unbiased.
    func updateContext(_ terms: [String]) async
}

extension StreamingSession {
    public func updateContext(_ terms: [String]) async {}
}

/// A backend that can transcribe live during recording. `AppController`
/// detects capability with a runtime conformance check; WhisperKit stays
/// batch-only.
public protocol StreamingTranscriptionBackend: TranscriptionBackend {
    /// Opens a session for one utterance. Throws if the engine isn't ready
    /// (e.g. `load` hasn't succeeded).
    func startStreamingSession() async throws -> any StreamingSession
}

/// Which output wins when a streaming session and the batch decoder are both
/// available for one utterance.
public enum FinalTranscriptPolicy: Sendable {
    /// Streamed text wins when the session survived and produced text
    /// (Apple Speech: its streamed final IS its best output).
    case streamPreferred
    /// Batch decode is the final text; the streamed result is only a rescue
    /// when batch throws or returns empty (Parakeet hybrid: EOU 120M
    /// partials for the overlay, TDT v3 accuracy for the inserted text).
    case batchFinal
}

/// The fallback invariant in one place: whichever policy runs, a transcript
/// is never silently lost — each side rescues the other.
public enum StreamingDictation {
    public static func finalTranscript(
        session: (any StreamingSession)?,
        policy: FinalTranscriptPolicy = .streamPreferred,
        fallback: @Sendable () async throws -> Transcript
    ) async throws -> (transcript: Transcript, streamed: Bool) {
        switch policy {
        case .streamPreferred:
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

        case .batchFinal:
            do {
                let transcript = try await fallback()
                if !transcript.text.isEmpty || session == nil {
                    // Batch won: never pay the EOU finalize wait for text we
                    // discard — cancel, don't finish.
                    if let session { await session.cancel() }
                    return (transcript, false)
                }
                // Batch empty but a session exists: try the streamed rescue.
                if let session, let rescued = await Self.rescue(session) {
                    return (rescued, true)
                }
                return (transcript, false)
            } catch {
                // Batch died: the streamed text is the rescue.
                if let session, let rescued = await Self.rescue(session) {
                    return (rescued, true)
                }
                throw error
            }
        }
    }

    /// Finish the session and return its text if usable; ends the session
    /// exactly once either way (cancel after a failed finish).
    private static func rescue(_ session: any StreamingSession) async -> Transcript? {
        do {
            let transcript = try await session.finish()
            return transcript.text.isEmpty ? nil : transcript
        } catch {
            await session.cancel()
            return nil
        }
    }
}

extension FinalTranscriptPolicy {
    /// Whisper never opens a session, so its value is inert — listed for
    /// exhaustiveness. Exhaustive switch on purpose: a new engine kind must
    /// make a deliberate policy choice here, not inherit one silently.
    public static func `for`(engine: TranscriptionEngineKind) -> FinalTranscriptPolicy {
        switch engine {
        case .parakeet: .batchFinal
        case .appleSpeech, .whisper: .streamPreferred
        }
    }
}
