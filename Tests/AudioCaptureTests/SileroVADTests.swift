import AVFoundation
import FabCore
import Foundation
import Testing

@testable import AudioCapture

/// Behavioral tests against the real Silero CoreML model. They run only when
/// the model is already installed (the app downloads it on launch) — CI or a
/// fresh checkout skips them instead of hitting the network.
@Suite struct SileroVADTests {
    private static var modelURL: URL {
        FabPaths.modelsDirectory
            .appendingPathComponent("vad", isDirectory: true)
            .appendingPathComponent("silero_vad.mlmodelc", isDirectory: true)
    }

    private static var modelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("model.mil").path)
    }

    @Test(.enabled(if: modelInstalled))
    func silenceComesBackEmpty() throws {
        let vad = try SileroVAD(modelURL: Self.modelURL)
        let silence = [Float](repeating: 0, count: 16_000 * 2)
        #expect(vad.trimSilence(silence, sampleRate: 16_000).isEmpty)
    }

    @Test(.enabled(if: modelInstalled))
    func noiseIsNotSpeech() throws {
        // Deterministic pseudo-noise at conversational amplitude — loud
        // enough that EnergyVAD would call it speech.
        let vad = try SileroVAD(modelURL: Self.modelURL)
        var seed: UInt64 = 0x5EED
        let noise = (0..<16_000 * 2).map { _ -> Float in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(seed >> 33) / Float(UInt32.max) - 0.5) * 0.1
        }
        #expect(vad.trimSilence(noise, sampleRate: 16_000).isEmpty)
    }

    @Test(.enabled(if: modelInstalled))
    func speechSurvivesAndSilenceIsTrimmed() throws {
        let speech = try Self.synthesizedSpeech()
        let secondOfSilence = [Float](repeating: 0, count: 16_000)
        let padded = secondOfSilence + speech + secondOfSilence

        let vad = try SileroVAD(modelURL: Self.modelURL)
        let trimmed = vad.trimSilence(padded, sampleRate: 16_000)

        #expect(!trimmed.isEmpty)
        // Both silent seconds mostly gone (padding keeps ≤0.2 s each side)…
        #expect(trimmed.count < padded.count - 16_000)
        // …but the speech itself intact.
        #expect(trimmed.count >= speech.count)
    }

    /// "hello world" via the system synthesizer, as 16 kHz Float32.
    private static func synthesizedSpeech() throws -> [Float] {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEF32@16000", "hello world"]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: wav)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
