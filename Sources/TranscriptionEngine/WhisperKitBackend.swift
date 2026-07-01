import FabCore
import Foundation
import WhisperKit

/// `WhisperKit` is an open class without a Sendable conformance. Every
/// instance we create is confined to the `WhisperKitBackend` actor — it never
/// escapes `load`/`transcribe`/`unload` — so treating it as Sendable to
/// satisfy region-isolation checking at the actor boundary is safe.
extension WhisperKit: @retroactive @unchecked Sendable {}

/// Whisper models compiled to CoreML, running on ANE/GPU via WhisperKit.
///
/// Models are downloaded on demand from the argmaxinc/whisperkit-coreml
/// Hugging Face repo into ~/Library/Application Support/fabulous/models/.
public actor WhisperKitBackend: TranscriptionBackend {
    private var whisperKit: WhisperKit?
    private var loadedModel: ModelDescriptor?
    private let modelsDirectory: URL

    public init(modelsDirectory: URL = FabPaths.modelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public func load(model: ModelDescriptor) async throws {
        if whisperKit != nil, loadedModel == model { return }
        whisperKit = nil
        loadedModel = nil

        try FabPaths.ensureDirectoryExists(modelsDirectory)
        let config = WhisperKitConfig(
            model: model.id,
            downloadBase: modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        loadedModel = model
    }

    public func transcribe(_ audio: AudioBuffer, language: Language?) async throws -> Transcript {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard audio.sampleRate == Double(WhisperKit.sampleRate) else {
            throw TranscriptionError.unsupportedSampleRate(audio.sampleRate)
        }
        guard !audio.isEmpty else {
            return Transcript(text: "", audioDuration: 0)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language?.rawValue,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Utterances longer than Whisper's 30 s window get chunked on
            // silence rather than truncated.
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(
            audioArray: audio.samples,
            decodeOptions: options
        )
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Transcript(text: Self.stripSpecialTokens(from: text), audioDuration: audio.duration)
    }

    public func unload() {
        whisperKit = nil
        loadedModel = nil
    }

    /// Defensive cleanup: `skipSpecialTokens` should already remove markers
    /// like `<|startoftranscript|>`, but older models occasionally leak them.
    static func stripSpecialTokens(from text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
