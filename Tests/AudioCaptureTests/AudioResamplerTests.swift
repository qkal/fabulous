import AudioCapture
import AVFoundation
import Testing

@Suite("AudioResampler")
struct AudioResamplerTests {
    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        seconds: Double,
        frequency: Float = 440
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = 0.5 * sin(2 * .pi * frequency * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func targetFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    @Test func downsamples48kToRoughlyOneThird() throws {
        let input = makeBuffer(sampleRate: 48_000, channels: 1, seconds: 1)
        let resampler = try #require(
            AudioResampler(from: input.format, to: targetFormat())
        )
        let output = try #require(resampler.convert(input))

        // The converter's filter delay withholds a handful of samples, so
        // allow a small shortfall but no overshoot beyond rounding.
        #expect(output.count > 15_000)
        #expect(output.count <= 16_064)
    }

    @Test func downmixesStereoToMono() throws {
        let input = makeBuffer(sampleRate: 44_100, channels: 2, seconds: 0.5)
        let resampler = try #require(
            AudioResampler(from: input.format, to: targetFormat())
        )
        let output = try #require(resampler.convert(input))
        #expect(output.count > 7_000)
        #expect(output.count <= 8_064)
    }

    @Test func preservesSignalEnergy() throws {
        let input = makeBuffer(sampleRate: 48_000, channels: 1, seconds: 1)
        let resampler = try #require(
            AudioResampler(from: input.format, to: targetFormat())
        )
        let output = try #require(resampler.convert(input))

        // A 0.5-amplitude sine has RMS ≈ 0.354; resampling shouldn't change that.
        var sum: Float = 0
        for sample in output {
            sum += sample * sample
        }
        let rms = (sum / Float(output.count)).squareRoot()
        #expect(abs(rms - 0.354) < 0.05)
    }

    @Test func streamingConversionIsContinuous() throws {
        // Feeding two consecutive buffers must not reset converter state:
        // total output should be about the sum of the parts.
        let first = makeBuffer(sampleRate: 48_000, channels: 1, seconds: 0.5)
        let second = makeBuffer(sampleRate: 48_000, channels: 1, seconds: 0.5)
        let resampler = try #require(
            AudioResampler(from: first.format, to: targetFormat())
        )
        let total = try #require(resampler.convert(first)).count
            + (try #require(resampler.convert(second))).count
        #expect(total > 15_000)
        #expect(total <= 16_128)
    }
}
