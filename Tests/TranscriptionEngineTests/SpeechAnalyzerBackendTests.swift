import AVFoundation
import FabCore
import Foundation
import Testing

@testable import TranscriptionEngine

/// Real-ASR smoke test: synthesizes speech with `say`, runs it through the
/// actual SpeechAnalyzer backend, and checks the words come back. Gated
/// behind FAB_REAL_ASR=1 because it downloads OS speech assets on first run
/// and needs macOS 26 — not something `swift test` should do by default.
@Suite struct SpeechAnalyzerBackendTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FAB_REAL_ASR"] == "1"))
    func transcribesSynthesizedSpeech() async throws {
        guard #available(macOS 26.0, *) else { return }

        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-smoke-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEF32@16000", "hello world this is a dictation test"]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let audio = try Self.monoFloatBuffer(from: wav)
        #expect(audio.duration > 1)

        let backend = SpeechAnalyzerBackend()
        try await backend.load(model: .appleSpeech)
        let transcript = try await backend.transcribe(audio, language: nil)

        let lowered = transcript.text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("dictation"))
    }

    private static func monoFloatBuffer(from url: URL) throws -> FabCore.AudioBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return FabCore.AudioBuffer(samples: samples, sampleRate: format.sampleRate)
    }
}
