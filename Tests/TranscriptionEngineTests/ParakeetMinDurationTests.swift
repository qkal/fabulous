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

    @Test func shortBufferIsPaddedToExactFloor() {
        // 0.2 s at 16 kHz = 3200 samples — below FluidAudio's measured
        // 4800-sample invalidAudioData cliff.
        let short = FabCore.AudioBuffer(
            samples: [Float](repeating: 0.1, count: 3_200), sampleRate: 16_000)
        let padded = ParakeetBackend.paddedToBatchFloor(short)
        #expect(padded.samples.count == 4_800)
        // Original audio is a prefix; the tail is digital silence.
        #expect(Array(padded.samples.prefix(3_200)) == short.samples)
        #expect(padded.samples.suffix(1_600).allSatisfy { $0 == 0 })
        #expect(padded.sampleRate == 16_000)
    }

    @Test func longBufferIsUntouched() {
        let ok = FabCore.AudioBuffer(
            samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        let padded = ParakeetBackend.paddedToBatchFloor(ok)
        #expect(padded.samples.count == 8_000)
    }
}
