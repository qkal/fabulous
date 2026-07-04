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

    /// NVIDIA Parakeet via FluidAudio (CoreML). One catalog entry covers
    /// BOTH model sets it needs: TDT 0.6b v3 (batch decode + fallback) and
    /// EOU 120M (streaming). Size is their sum.
    public static let parakeetV3 = ModelDescriptor(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet v3",
        // Task 1 finding: v3 (~461 MB) + EOU 160ms (~214 MB) required files,
        // measured via HuggingFace's tree API (not yet a local download).
        approximateSizeMB: 674
    )
}

/// Which ASR engine turns audio into text. A user preference; the Whisper
/// model *variant* remains a separate choice (`ModelCatalog`).
public enum TranscriptionEngineKind: String, Sendable, Codable, CaseIterable {
    case whisper
    /// Apple SpeechAnalyzer — experimental, macOS 26+ only.
    case appleSpeech = "apple-speech"
    /// Parakeet via FluidAudio — experimental. Streams with the EOU 120M
    /// model; batch/fallback decodes with TDT 0.6b v3.
    case parakeet

    public var displayName: String {
        switch self {
        case .whisper: "Whisper"
        case .appleSpeech: "Apple Speech (experimental)"
        case .parakeet: "Parakeet (experimental)"
        }
    }
}

/// The models fabulous offers in the UI, best first.
public enum ModelCatalog {
    /// Whisper model variants — the choice `selectedModelID` ranges over.
    public static let whisperVariants: [ModelDescriptor] = [
        .whisperLargeV3Turbo, .whisperSmall, .whisperBase,
    ]

    /// Everything the Models tab shows (downloadable/deletable on disk).
    /// Apple Speech is absent by design: its assets are OS-managed.
    public static let all: [ModelDescriptor] = whisperVariants + [.parakeetV3]

    public static let recommended: ModelDescriptor = .whisperLargeV3Turbo

    /// Resolves any engine/model ID we ever persist (history rows, menu
    /// stats) — including Apple Speech, which is not in `all`.
    public static func descriptor(withID id: String) -> ModelDescriptor? {
        if id == ModelDescriptor.appleSpeech.id { return .appleSpeech }
        return all.first { $0.id == id }
    }
}
