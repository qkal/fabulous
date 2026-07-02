import Foundation

/// Identifies an ASR model a backend can load.
///
/// `id` is backend-specific — for WhisperKit it is the variant name used by
/// the argmaxinc/whisperkit-coreml Hugging Face repo (matched by substring,
/// so "base" resolves to "openai_whisper-base").
public struct ModelDescriptor: Sendable, Equatable, Codable {
    public var id: String
    public var displayName: String
    /// Rough on-disk size, for the model management UI. 0 = unknown.
    public var approximateSizeMB: Int

    public init(id: String, displayName: String, approximateSizeMB: Int = 0) {
        self.id = id
        self.displayName = displayName
        self.approximateSizeMB = approximateSizeMB
    }

    /// Small and quick to download; the fallback for low-RAM machines.
    public static let whisperBase = ModelDescriptor(
        id: "base",
        displayName: "Whisper Base",
        approximateSizeMB: 150
    )

    /// Middle ground: noticeably better accuracy than base, still light.
    public static let whisperSmall = ModelDescriptor(
        id: "small",
        displayName: "Whisper Small",
        approximateSizeMB: 480
    )

    /// Recommended default on machines with RAM to spare.
    public static let whisperLargeV3Turbo = ModelDescriptor(
        id: "large-v3_turbo",
        displayName: "Whisper Large v3 Turbo",
        approximateSizeMB: 1600
    )

    /// Apple's on-device SpeechAnalyzer (macOS 26+). Assets are managed by
    /// the OS, so this never appears in the download/delete Models UI —
    /// it exists so history rows and the backend API can name the engine.
    public static let appleSpeech = ModelDescriptor(
        id: "apple-speech",
        displayName: "Apple Speech",
        approximateSizeMB: 0
    )
}

/// Which ASR engine turns audio into text. A user preference; the Whisper
/// model *variant* remains a separate choice (`ModelCatalog`).
public enum TranscriptionEngineKind: String, Sendable, Codable, CaseIterable {
    case whisper
    /// Apple SpeechAnalyzer — experimental, macOS 26+ only.
    case appleSpeech = "apple-speech"

    public var displayName: String {
        switch self {
        case .whisper: "Whisper"
        case .appleSpeech: "Apple Speech (experimental)"
        }
    }
}

/// The models fabulous offers in the UI, best first.
public enum ModelCatalog {
    public static let all: [ModelDescriptor] = [
        .whisperLargeV3Turbo, .whisperSmall, .whisperBase,
    ]

    public static let recommended: ModelDescriptor = .whisperLargeV3Turbo

    public static func descriptor(withID id: String) -> ModelDescriptor? {
        all.first { $0.id == id }
    }
}
