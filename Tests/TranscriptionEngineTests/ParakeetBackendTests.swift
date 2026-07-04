import AVFoundation
import FabCore
import Foundation
import Testing
@testable import TranscriptionEngine

struct ParakeetBackendTests {
    @Test func transcribeWithoutLoadThrowsModelNotLoaded() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let audio = FabCore.AudioBuffer(samples: [0.1, 0.2], sampleRate: 16_000)
        await #expect(throws: TranscriptionError.self) {
            _ = try await backend.transcribe(audio, language: nil)
        }
    }

    @Test func loadRejectsNonParakeetDescriptor() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        await #expect(throws: (any Error).self) {
            try await backend.load(model: .whisperBase)
        }
    }

    // MARK: - Real-engine tests

    /// FAB_REAL_ASR=1 opts in; additionally auto-skip unless the Parakeet
    /// models are already installed (they are ~674 MB — tests never
    /// download). Mirrors `SpeechAnalyzerBackendTests`'s gate, plus the
    /// on-disk check since Parakeet models (unlike OS-managed SpeechAnalyzer
    /// assets) are ours to install via the app first.
    private static var realASREnabled: Bool {
        ProcessInfo.processInfo.environment["FAB_REAL_ASR"] == "1"
            && ParakeetLayout.isInstalled(downloadBase: FabPaths.modelsDirectory)
    }

    @Test(.enabled(if: realASREnabled))
    func batchDecodesSynthesizedSpeech() async throws {
        let audio = try Self.synthesize(text: "hello world this is a test")
        let backend = ParakeetBackend()
        try await backend.load(model: .parakeetV3)
        let transcript = try await backend.transcribe(audio, language: nil)
        let lowered = transcript.text.lowercased()
        #expect(lowered.contains("hello"))
        #expect(lowered.contains("test"))
    }

    @Test(.enabled(if: realASREnabled))
    func streamingSessionYieldsPartialsAndFinal() async throws {
        let audio = try Self.synthesize(text: "streaming test one two three")
        let backend = ParakeetBackend()
        try await backend.load(model: .parakeetV3)
        let session = try await backend.startStreamingSession()

        let partialCount = Task {
            var count = 0
            for await _ in session.partials { count += 1 }
            return count
        }
        // Feed in ~250 ms chunks like the app's feed timer does.
        let chunk = 4_000
        var start = 0
        while start < audio.samples.count {
            let end = min(start + chunk, audio.samples.count)
            await session.feed(Array(audio.samples[start..<end]))
            start = end
        }
        let transcript = try await session.finish()
        let lowered = transcript.text.lowercased()
        #expect(lowered.contains("streaming"))
        #expect(lowered.contains("three"))
        #expect(await partialCount.value > 0)
    }

    /// Synthesizes speech with `say` and decodes it into a mono Float32
    /// buffer, same approach as `SpeechAnalyzerBackendTests.monoFloatBuffer`
    /// (that helper is `private` to its own suite, so it isn't reusable
    /// here — replicated rather than shared).
    private static func synthesize(text: String) throws -> FabCore.AudioBuffer {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-parakeet-smoke-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: wav)
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
