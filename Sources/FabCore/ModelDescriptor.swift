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

    /// The vertical-slice default: small, quick to download, good enough
    /// to prove the pipeline.
    public static let whisperBase = ModelDescriptor(
        id: "base",
        displayName: "Whisper Base",
        approximateSizeMB: 150
    )

    /// Recommended default for machines with RAM to spare (later phase).
    public static let whisperLargeV3Turbo = ModelDescriptor(
        id: "large-v3_turbo",
        displayName: "Whisper Large v3 Turbo",
        approximateSizeMB: 1600
    )
}
