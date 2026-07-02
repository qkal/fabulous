import AVFoundation
import FabCore
import Foundation
import Testing
import TextInjector
import TranscriptionEngine

@testable import AudioCapture

/// End-to-end pipeline test: everything between the microphone tap and the
/// injection decision, composed the way `AppController` composes it, minus
/// the parts that need real hardware, a real model, or a real frontmost app.
///
///   48 kHz capture → TapProcessor (resample to 16 kHz) → VAD trim
///   → TranscriptionBackend (fake, contract-checking) → ReplacementDictionary
///   → StrategySelector
///
/// Unit tests cover each stage alone; this catches the seams — sample-rate
/// mismatches, a VAD that eats speech, post-processing order — that
/// previously only manual dictation could.
@Suite struct DictationPipelineTests {
    /// A backend that verifies the audio contract and returns canned text.
    actor FakeBackend: TranscriptionBackend {
        private(set) var received: FabCore.AudioBuffer?
        private var loaded = false
        let cannedText: String

        init(cannedText: String) {
            self.cannedText = cannedText
        }

        func load(model: ModelDescriptor) async throws {
            loaded = true
        }

        func transcribe(
            _ audio: FabCore.AudioBuffer,
            language: Language?,
            onProgress: (@Sendable (Double) -> Void)?
        ) async throws -> Transcript {
            guard loaded else { throw TranscriptionError.modelNotLoaded }
            guard audio.sampleRate == AudioRecorder.targetSampleRate else {
                throw TranscriptionError.unsupportedSampleRate(audio.sampleRate)
            }
            received = audio
            return Transcript(text: cannedText, audioDuration: audio.duration)
        }

        func unload() {
            loaded = false
        }
    }

    @Test func fullPipelineFromCaptureToInjectionDecision() async throws {
        // -- Capture: one second of near-silence, a 440 Hz "utterance", more
        // near-silence, at a mic-realistic 48 kHz. (A tone is speech enough
        // for EnergyVAD; the neural VAD has its own suite.)
        let capture = Self.captureBuffer(
            segments: [(1.0, 0.0005), (2.0, 0.25), (1.0, 0.0005)],
            sampleRate: 48_000
        )

        // -- Tap → 16 kHz mono, fed in tap-sized slices like the engine does.
        let processor = TapProcessor(targetSampleRate: AudioRecorder.targetSampleRate)
        for slice in Self.slices(of: capture, frames: 4096) {
            processor.process(slice)
        }
        let resampled = processor.drain()
        let expectedFrames = 4.0 * AudioRecorder.targetSampleRate
        #expect(abs(Double(resampled.count) - expectedFrames) < 0.05 * expectedFrames)

        // -- VAD: both silent seconds go, the utterance stays.
        let vad = EnergyVAD()
        let trimmed = vad.trimSilence(resampled, sampleRate: AudioRecorder.targetSampleRate)
        let trimmedSeconds = Double(trimmed.count) / AudioRecorder.targetSampleRate
        #expect(trimmedSeconds > 1.9 && trimmedSeconds < 2.5)

        // -- Transcribe via the backend protocol.
        let backend = FakeBackend(cannedText: "hello world comma testing")
        try await backend.load(model: .whisperBase)
        let audio = FabCore.AudioBuffer(
            samples: trimmed,
            sampleRate: AudioRecorder.targetSampleRate
        )
        let transcript = try await backend.transcribe(audio, language: nil)
        let heard = await backend.received
        #expect(heard?.duration == audio.duration)

        // -- Post-process with a user replacement.
        let processorChain = ReplacementDictionary(entries: [
            .init(pattern: "comma", replacement: ",")
        ])
        let text = try await processorChain.process(transcript.text)
        #expect(text == "hello world , testing")

        // -- Injection decision for a normal app context.
        let decision = StrategySelector().select(for: InjectionContext(
            frontmostBundleID: "com.apple.TextEdit",
            secureInputActive: false,
            accessibilityTrusted: true
        ))
        #expect(decision == .attempt(chain: [.axInsert, .paste, .keystrokes]))
    }

    @Test func silentRecordingShortCircuitsBeforeTheBackend() {
        let processor = TapProcessor(targetSampleRate: AudioRecorder.targetSampleRate)
        for slice in Self.slices(
            of: Self.captureBuffer(segments: [(2.0, 0.0005)], sampleRate: 48_000),
            frames: 4096
        ) {
            processor.process(slice)
        }
        let trimmed = EnergyVAD().trimSilence(
            processor.drain(),
            sampleRate: AudioRecorder.targetSampleRate
        )
        // Empty trim is the "skip transcription entirely" signal.
        #expect(trimmed.isEmpty)
    }

    @Test func secureInputRefusalReachesTheSafetyNetPath() {
        let decision = StrategySelector().select(for: InjectionContext(
            frontmostBundleID: "com.1password.1password",
            secureInputActive: true,
            accessibilityTrusted: true
        ))
        #expect(decision == .refuse(.secureInputActive))
    }

    // MARK: - Fixtures

    /// Mono buffer of consecutive (seconds, amplitude) segments; amplitude
    /// drives a 440 Hz tone with a touch of deterministic noise so "silence"
    /// has a realistic dither floor instead of digital zero.
    private static func captureBuffer(
        segments: [(seconds: Double, amplitude: Float)],
        sampleRate: Double
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let totalFrames = segments.reduce(0) { $0 + Int($1.seconds * sampleRate) }
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(totalFrames)
        )!
        let channel = buffer.floatChannelData![0]
        var frame = 0
        var noiseState: UInt64 = 0x5EED
        for segment in segments {
            for _ in 0..<Int(segment.seconds * sampleRate) {
                noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = (Float(noiseState >> 33) / Float(UInt32.max) - 0.5) * 0.001
                let tone = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate))
                channel[frame] = segment.amplitude * tone + noise
                frame += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        return buffer
    }

    /// Copies the buffer into tap-callback-sized pieces.
    private static func slices(
        of buffer: AVAudioPCMBuffer,
        frames sliceFrames: Int
    ) -> [AVAudioPCMBuffer] {
        let source = buffer.floatChannelData![0]
        let total = Int(buffer.frameLength)
        var result: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < total {
            let count = min(sliceFrames, total - offset)
            let slice = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: AVAudioFrameCount(count)
            )!
            slice.floatChannelData![0].update(from: source + offset, count: count)
            slice.frameLength = AVAudioFrameCount(count)
            result.append(slice)
            offset += count
        }
        return result
    }
}
