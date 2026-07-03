import FoundationModels

@available(macOS 26.0, *)
@Generable
struct CleanupResult {
    @Guide(description: "The cleaned-up transcript text, and nothing else.")
    var cleanedText: String
}

/// The real model behind `LanguageModelRequesting`. A fresh session per
/// dictation: sessions accumulate context, and reuse would grow the
/// prompt and leak text across dictations. `prepare` warms at most one
/// session during recording; `PreparedSession.take` guarantees it serves
/// at most one dictation. The model itself stays resident (prewarm).
@available(macOS 26.0, *)
public actor FoundationModelRequester: LanguageModelRequesting {
    private var prepared = PreparedSession<LanguageModelSession>()

    public init() {}

    /// Builds and prewarms a session while the user is still speaking.
    /// Best-effort: session construction doesn't throw, and a stale
    /// session is silently discarded at cleanup time.
    public func prepare(instructions: String) async {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        prepared.store(session, instructions: instructions)
    }

    public func cleanup(instructions: String, transcript: String) async throws -> String {
        let session = prepared.take(matching: instructions)
            ?? LanguageModelSession(instructions: instructions)
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
