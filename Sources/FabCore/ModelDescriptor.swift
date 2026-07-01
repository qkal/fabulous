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
