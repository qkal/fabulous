import FabCore
import Testing
@testable import TranscriptionEngine

@Suite("Parakeet min duration")
struct ParakeetMinDurationTests {
    @Test func subThresholdBufferIsBelowMinimum() {
        // 0.05 s at 16 kHz = 800 samples — below the batch decoder floor.
        let short = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 800), sampleRate: 16_000)
        #expect(ParakeetBackend.isBelowBatchMinimum(short))
    }

    @Test func aboveThresholdBufferIsAllowed() {
        // 0.5 s at 16 kHz = 8000 samples — comfortably decodable.
        let ok = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        #expect(!ParakeetBackend.isBelowBatchMinimum(ok))
    }
}
