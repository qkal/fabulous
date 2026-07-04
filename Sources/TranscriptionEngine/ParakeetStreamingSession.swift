import FabCore
import FluidAudio
import Foundation

/// One utterance streamed through FluidAudio's `StreamingEouAsrManager`
/// (Parakeet EOU 120M — deliberately a smaller model than the batch path's
/// TDT v3; see docs/specs/parakeet-backend.md).
///
/// End-of-utterance auto-detection is FluidAudio's feature, not ours: the
/// hotkey release decides when the utterance ends, so the EOU callback is
/// never registered and the debounce is set high enough (backend init) to
/// never fire mid-dictation.
actor ParakeetStreamingSession: StreamingSession {
    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let manager: StreamingEouAsrManager
    private var ended = false

    init(manager: StreamingEouAsrManager) async {
        self.manager = manager
        (partials, partialsContinuation) = AsyncStream.makeStream()
        let continuation = partialsContinuation
        await manager.setPartialCallback { partial in
            continuation.yield(partial)
        }
    }

    func feed(_ samples: [Float]) async {
        guard !ended, let buffer = PCMBufferConversion.buffer(from: samples) else { return }
        // A failed chunk is not fatal: the batch fallback still has the
        // full recording. Log-and-continue matches the seam's contract.
        do {
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            NSLog("fabulous: parakeet streaming feed failed (\(error))")
        }
    }

    func finish() async throws -> Transcript {
        guard !ended else { return Transcript(text: "", audioDuration: nil) }
        ended = true
        defer { partialsContinuation.finish() }
        do {
            let text = try await manager.finish()
            await manager.reset()
            return Transcript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                audioDuration: nil
            )
        } catch {
            await manager.reset()
            throw error
        }
    }

    func cancel() async {
        guard !ended else { return }
        ended = true
        partialsContinuation.finish()
        await manager.reset()
    }
}
