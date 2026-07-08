import AVFoundation
import FabCore
import Foundation
import Testing

@testable import AudioCapture
@testable import TranscriptionEngine

/// Streaming-path seams: session text wins over batch, every failure mode
/// falls back to batch, feeds flow through the drainNew cursor in order.
@Suite struct StreamingPipelineTests {
    actor FakeSession: StreamingSession {
        private(set) var fed: [[Float]] = []
        private(set) var cancelled = false
        private(set) var finished = false
        let finishResult: Result<Transcript, Error>
        nonisolated let partials: AsyncStream<String>
        private let partialsContinuation: AsyncStream<String>.Continuation

        init(finishResult: Result<Transcript, Error>) {
            self.finishResult = finishResult
            (partials, partialsContinuation) = AsyncStream.makeStream()
        }

        func feed(_ samples: [Float]) {
            guard !finished, !cancelled else { return }
            fed.append(samples)
            partialsContinuation.yield("partial \(fed.count)")
        }

        func finish() throws -> Transcript {
            finished = true
            partialsContinuation.finish()
            return try finishResult.get()
        }

        func cancel() {
            cancelled = true
            partialsContinuation.finish()
        }
    }

    struct SessionDied: Error {}

    private static func batchTranscript() -> Transcript {
        Transcript(text: "batch text", audioDuration: 1)
    }

    @Test func sessionTranscriptWinsAndBatchIsSkipped() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1))
        )
        // Safe: finalTranscript never runs the fallback when finish()
        // succeeds, so this flag has exactly one potential writer and no
        // concurrent access — the unsafe opt-out is for the @Sendable
        // closure's benefit only.
        nonisolated(unsafe) var batchRan = false
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session,
            fallback: {
                batchRan = true
                return Self.batchTranscript()
            }
        )
        #expect(transcript.text == "streamed text")
        #expect(streamed)
        #expect(!batchRan)
    }

    @Test func finishFailureFallsBackToBatch() async throws {
        let session = FakeSession(finishResult: .failure(SessionDied()))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session,
            fallback: { Self.batchTranscript() }
        )
        #expect(transcript.text == "batch text")
        #expect(!streamed)
        // The dead session was cancelled, not leaked.
        #expect(await session.cancelled)
    }

    @Test func emptyStreamedTranscriptFallsBackToBatch() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "", audioDuration: 1))
        )
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session,
            fallback: { Self.batchTranscript() }
        )
        #expect(transcript.text == "batch text")
        #expect(!streamed)
        // finish() succeeded, so the session is not cancelled.
        #expect(await session.finished)
        #expect(await !session.cancelled)
    }

    @Test func missingSessionFallsBackToBatch() async throws {
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: nil,
            fallback: { Self.batchTranscript() }
        )
        #expect(transcript.text == "batch text")
        #expect(!streamed)
    }

    @Test func feedAfterFinishIsIgnored() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "t", audioDuration: 0))
        )
        await session.feed([0.1])
        _ = try await session.finish()
        await session.feed([0.2])
        #expect(await session.fed.count == 1)
    }

    /// Capture → drainNew → feed: chunks arrive in order and cover exactly
    /// what was captured, mirroring the AppController feed loop.
    @Test func drainNewFeedsChunksInOrder() async {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "", audioDuration: 0))
        )
        let processor = TapProcessor(targetSampleRate: 16_000)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        for chunkValue in [Float(0.1), 0.2, 0.3] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
            let channel = buffer.floatChannelData![0]
            for i in 0..<100 { channel[i] = chunkValue }
            buffer.frameLength = 100
            processor.process(buffer)
            await session.feed(processor.drainNew())
        }
        let fed = await session.fed
        #expect(fed.count == 3)
        #expect(fed.map(\.count) == [100, 100, 100])
        #expect(abs(fed[2][0] - 0.3) < 0.001)
    }

    // MARK: .batchFinal (hybrid) matrix

    @Test func batchFinalUsesBatchAndCancelsSession() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Self.batchTranscript() })
        #expect(transcript.text == "batch text")
        #expect(!streamed)
        // EOU finalize wait is never paid for text we discard.
        #expect(await session.cancelled)
        #expect(await !session.finished)
    }

    @Test func batchFinalRescuesFromStreamWhenBatchThrows() async throws {
        struct BatchDied: Error {}
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { throw BatchDied() })
        #expect(transcript.text == "streamed text")
        #expect(streamed)
        #expect(await session.finished)
    }

    @Test func batchFinalRescuesFromStreamWhenBatchIsEmpty() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "streamed text", audioDuration: 1)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Transcript(text: "", audioDuration: 0) })
        #expect(transcript.text == "streamed text")
        #expect(streamed)
        // Rescue ends the session via finish(), exactly once.
        #expect(await session.finished)
        #expect(await !session.cancelled)
    }

    @Test func batchFinalEmptyEverywhereReturnsEmptyBatch() async throws {
        let session = FakeSession(
            finishResult: .success(Transcript(text: "", audioDuration: 0)))
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: session, policy: .batchFinal,
            fallback: { Transcript(text: "", audioDuration: 0) })
        #expect(transcript.text.isEmpty)
        #expect(!streamed)
        // Empty rescue still ends the session via finish(), exactly once.
        #expect(await session.finished)
        #expect(await !session.cancelled)
    }

    @Test func batchFinalThrowsBatchErrorWhenRescueAlsoDies() async throws {
        struct BatchDied: Error {}
        let session = FakeSession(finishResult: .failure(SessionDied()))
        await #expect(throws: BatchDied.self) {
            _ = try await StreamingDictation.finalTranscript(
                session: session, policy: .batchFinal,
                fallback: { throw BatchDied() })
        }
        // Session must still be ended exactly once (cancel after failed finish).
        #expect(await session.cancelled)
    }

    @Test func batchFinalWithoutSessionJustRunsBatch() async throws {
        let (transcript, streamed) = try await StreamingDictation.finalTranscript(
            session: nil, policy: .batchFinal,
            fallback: { Self.batchTranscript() })
        #expect(transcript.text == "batch text")
        #expect(!streamed)
    }

    @Test func policyPerEngine() {
        #expect(FinalTranscriptPolicy.for(engine: .parakeet) == .batchFinal)
        #expect(FinalTranscriptPolicy.for(engine: .appleSpeech) == .streamPreferred)
        #expect(FinalTranscriptPolicy.for(engine: .whisper) == .streamPreferred)
    }
}
