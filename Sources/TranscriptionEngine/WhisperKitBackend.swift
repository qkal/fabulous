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
        // Prefer the already-installed folder: loading is then purely local
        // (works offline, no hub round-trip). Fall back to letting WhisperKit
        // download when the model isn't on disk yet — also the path taken
        // when the on-disk manifest fails to verify (F5: never trust
        // stale/tampered files, force a fresh download instead).
        let installed = ModelLayout.installedFolder(for: model, downloadBase: modelsDirectory)
            .flatMap { folder -> URL? in
                guard ModelLayout.isComplete(folder) else { return nil }
                guard ModelManifestStore.verify(root: folder, relativeComponents: ModelLayout.requiredComponents) else {
                    NSLog("fabulous: model manifest verification failed — will re-download \(model.id)")
                    return nil
                }
                return folder
            }
        let config = WhisperKitConfig(
            model: model.id,
            downloadBase: modelsDirectory,
            modelFolder: installed?.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        loadedModel = model
    }

    public var currentModel: ModelDescriptor? { loadedModel }

    public func transcribe(
        _ audio: AudioBuffer,
        language: Language?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
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
        // WhisperKit fills its `progress` per decoding window (and swaps in
        // a fresh Progress after each finished run). Poll it while the
        // decode runs; this task inherits actor isolation and interleaves
        // with the awaited transcribe call.
        var poller: Task<Void, Never>?
        if let onProgress {
            poller = Task {
                // Forward only fresh forward movement: re-reporting an
                // unchanged fraction would invalidate the progress UI for
                // no visible change, and a stale Progress from the previous
                // run reads 1.0 (filtered by `< 1`).
                var lastReported: Double = 0
                while !Task.isCancelled {
                    if let fraction = self.whisperKit?.progress.fractionCompleted,
                       fraction > lastReported, fraction < 1 {
                        lastReported = fraction
                        onProgress(fraction)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        defer { poller?.cancel() }

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
