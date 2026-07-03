import FoundationModels

@available(macOS 26.0, *)
@Generable
struct CleanupResult {
    @Guide(description: "The cleaned-up transcript text, and nothing else.")
    var cleanedText: String
}

/// The real model behind `LanguageModelRequesting`. A fresh session per
/// dictation: sessions accumulate context, and reuse would grow the
/// prompt and leak text across dictations. The model itself stays
/// resident (prewarm) — per-session setup is cheap.
@available(macOS 26.0, *)
public struct FoundationModelRequester: LanguageModelRequesting {
    public init() {}

    public func cleanup(instructions: String, transcript: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: transcript,
            generating: CleanupResult.self,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content.cleanedText
    }

    /// Loads the model into memory ahead of the first dictation.
    public static func prewarm() {
        LanguageModelSession().prewarm()
    }
}
