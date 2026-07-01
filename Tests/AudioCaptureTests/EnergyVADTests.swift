import AudioCapture
import Foundation
import Testing

@Suite("EnergyVAD")
struct EnergyVADTests {
    let sampleRate = 16_000.0
    let vad = EnergyVAD()

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    private func tone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            amplitude * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
    }

    @Test func pureSilenceTrimsToEmpty() {
        #expect(vad.trimSilence(silence(seconds: 2), sampleRate: sampleRate).isEmpty)
    }

    @Test func emptyInputStaysEmpty() {
        #expect(vad.trimSilence([], sampleRate: sampleRate).isEmpty)
    }

    @Test func trimsLeadingAndTrailingSilence() {
        let signal = silence(seconds: 1) + tone(seconds: 0.5) + silence(seconds: 1)
        let trimmed = vad.trimSilence(signal, sampleRate: sampleRate)

        // Expect the 0.5 s tone plus up to `padding` on each side,
        // quantized to frame boundaries.
        let minExpected = Int(0.5 * sampleRate)
        let maxExpected = Int((0.5 + 2 * vad.padding) * sampleRate)
            + 2 * Int(vad.frameDuration * sampleRate)
        #expect(trimmed.count >= minExpected)
        #expect(trimmed.count <= maxExpected)
    }

    @Test func keptAudioContainsTheTone() {
        let signal = silence(seconds: 1) + tone(seconds: 0.5) + silence(seconds: 1)
        let trimmed = vad.trimSilence(signal, sampleRate: sampleRate)
        let peak = trimmed.map(abs).max() ?? 0
        #expect(peak > 0.4)
    }

    @Test func allSpeechIsKeptWhole() {
        let signal = tone(seconds: 1)
        let trimmed = vad.trimSilence(signal, sampleRate: sampleRate)
        #expect(trimmed.count == signal.count)
    }

    @Test func quietNoiseBelowThresholdIsSilence() {
        let noise = (0..<Int(sampleRate)).map { _ in Float.random(in: -0.001...0.001) }
        #expect(vad.trimSilence(noise, sampleRate: sampleRate).isEmpty)
    }
}
