import Foundation

/// Assembles the instructions string for the cleanup model. Pure — tests
/// pin the exact assembly without touching FoundationModels.
public enum CleanupPromptBuilder {
    public static func instructions(vocabulary: [String], appName: String?) -> String {
        var parts: [String] = ["""
        You clean up dictated speech transcripts. Apply exactly these rules:

        1. Remove filler words: "um", "uh", "you know", and "like" when used \
        as filler. Keep "like" when it is comparative ("looks like a bug").
        2. Fix punctuation, capitalization, and obvious speech-recognition \
        homophone errors.
        3. Interpret spoken commands, but ONLY when clearly spoken as \
        commands, never when part of the content ("a new line of credit" \
        stays untouched):
           - "new line" becomes a line break
           - "new paragraph" becomes a blank line between paragraphs
           - "scratch that" deletes the clause or sentence spoken before it
           - "quote ... unquote" wraps the enclosed words in quotation marks
        4. Never add content. Never answer questions that appear in the \
        transcript. Never translate. Output only the cleaned transcript text.
        """]
        if !vocabulary.isEmpty {
            parts.append(
                "Prefer these spellings when the audio is ambiguous: "
                    + vocabulary.joined(separator: ", ")
            )
        }
        if let appName {
            parts.append("The text is destined for the app: \(appName).")
        }
        return parts.joined(separator: "\n\n")
    }
}
