import AVFoundation
import Foundation
import Testing

@testable import AudioCapture

@Suite struct TapProcessorDrainNewTests {
    /// 16 kHz mono buffer of constant value, `frames` long.
    private static func buffer(frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        let channel = buffer.floatChannelData![0]
        for i in 0..<frames { channel[i] = value }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    @Test func drainNewReturnsOnlySamplesSinceLastCall() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        let first = processor.drainNew()
        #expect(first.count == 100)
        #expect(first.allSatisfy { abs($0 - 0.1) < 0.001 })

        processor.process(Self.buffer(frames: 50, value: 0.2))
        let second = processor.drainNew()
        #expect(second.count == 50)
        #expect(second.allSatisfy { abs($0 - 0.2) < 0.001 })

        // Nothing new → empty, cheaply.
        #expect(processor.drainNew().isEmpty)
    }

    @Test func drainStillReturnsEverythingAfterIncrementalDrains() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        _ = processor.drainNew()
        processor.process(Self.buffer(frames: 50, value: 0.2))
        // drain() ignores the cursor: the full utterance, always.
        #expect(processor.drain().count == 150)
    }

    @Test func drainResetsTheCursor() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        _ = processor.drain()
        processor.process(Self.buffer(frames: 30, value: 0.3))
        #expect(processor.drainNew().count == 30)
    }

    /// Device hot-swap mid-recording changes the tap format; the converter
    /// rebuilds but the sample store — and the drainNew cursor — carry on.
    @Test func cursorSurvivesFormatChange() {
        let processor = TapProcessor(targetSampleRate: 16_000)
        processor.process(Self.buffer(frames: 100, value: 0.1))
        #expect(processor.drainNew().count == 100)

        // Same content at 48 kHz mono: resampler rebuilds, cursor holds.
        let format48 = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 1, interleaved: false
        )!
        let buffer48 = AVAudioPCMBuffer(pcmFormat: format48, frameCapacity: 4800)!
        let channel = buffer48.floatChannelData![0]
        for i in 0..<4800 { channel[i] = 0.2 }
        buffer48.frameLength = 4800

        processor.process(buffer48)
        let fresh = processor.drainNew()
        // 4800 frames at 48 kHz ≈ 1600 at 16 kHz (resampler edge slop OK).
        #expect(abs(fresh.count - 1600) < 300)
        #expect(processor.drain().count == 100 + fresh.count)
    }
}
