import Foundation

/// The result of one transcription pass.
public struct Transcript: Sendable, Equatable {
    public var text: String
    /// Duration of the audio that produced this transcript, if known.
    public var audioDuration: TimeInterval?

    public init(text: String, audioDuration: TimeInterval? = nil) {
        self.text = text
        self.audioDuration = audioDuration
    }
}

/// A spoken language, identified by its Whisper/ISO 639-1 code.
/// Pass `nil` wherever a `Language?` is expected to request auto-detection.
public struct Language: Sendable, Equatable, Codable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let english = Language(rawValue: "en")
    public static let german = Language(rawValue: "de")
    public static let french = Language(rawValue: "fr")
    public static let spanish = Language(rawValue: "es")
}
