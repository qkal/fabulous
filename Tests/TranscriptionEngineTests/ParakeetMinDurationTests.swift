import FabCore
import Testing
@testable import TranscriptionEngine

@Suite("Parakeet min duration")
struct ParakeetMinDurationTests {
    @Test func subThresholdBufferIsBelowMinimum() {
        // 0.025 s at 16 kHz = 400 samples — below the 0.05 s noise floor
        // (no real word is this short; padding rescues everything longer).
        let short = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 400), sampleRate: 16_000)
        #expect(ParakeetBackend.isBelowBatchMinimum(short))
    }

    @Test func aboveThresholdBufferIsAllowed() {
        // 0.2 s at 16 kHz = 3200 samples — a real blip: above the 0.05 s
        // noise floor but below the 4800-sample decoder cliff, so it is
        // allowed through and rescued by padding (see the padding tests).
        let blip = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 3_200), sampleRate: 16_000)
        #expect(!ParakeetBackend.isBelowBatchMinimum(blip))
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
