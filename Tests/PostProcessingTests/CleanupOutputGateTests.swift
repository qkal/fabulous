import PostProcessing
import Testing

/// The threshold is pinned by this corpus, not chosen by feel: every case
/// here is a real edit class the prompt sanctions (must pass) or a real
/// hallucination class from dogfood (must reject).
struct CleanupOutputGateTests {
    private func permits(_ raw: String, _ cleaned: String, vocab: [String] = []) -> Bool {
        CleanupOutputGate.permits(raw: raw, cleaned: cleaned, vocabulary: vocab)
    }

    // MARK: legitimate edits — must pass

    @Test func fillerRemovalPasses() {
        #expect(permits(
            "um so I think we should uh ship it you know",
            "So I think we should ship it."))
    }

    @Test func trailingScratchThatWipingEverythingPasses() {
        // Pure removal has zero novel words; empty-cleaned is handled
        // before the gate, but a partial wipe goes through it.
        #expect(permits(
            "send it tomorrow scratch that send it on Friday",
            "Send it on Friday."))
    }

    @Test func quoteUnquotePasses() {
        #expect(permits(
            "she said quote I will be late unquote",
            "She said \"I will be late\"."))
    }

    @Test func vocabularySubstitutionPasses() {
        #expect(permits(
            "the whisper kit backend is slow",
            "The WhisperKit backend is slow.",
            vocab: ["WhisperKit"]))
    }

    @Test func homophoneFixPasses() {
        #expect(permits(
            "their going to the store over they're",
            "They're going to the store over there."))
    }

    @Test func newLineCommandPasses() {
        #expect(permits(
            "call him now new line then email the team",
            "Call him now.\nThen email the team."))
    }

    @Test func numberNormalizationPasses() {
        // The model does this unprompted; one novel token in a sentence
        // must stay under threshold.
        #expect(permits(
            "twenty three people came to the meeting",
            "23 people came to the meeting."))
    }

    @Test func unchangedEchoPasses() {
        #expect(permits("ship it today", "ship it today"))
    }

    // MARK: hallucinations — must reject

    @Test func wholesaleRewriteRejected() {
        #expect(!permits(
            "remind me to call the dentist tomorrow morning",
            "Here is a summary of your recent activity and upcoming events."))
    }

    @Test func answeredQuestionRejected() {
        // Model answers instead of transcribing — output is mostly novel.
        #expect(!permits(
            "what should I write here",
            "You could start with a brief introduction about yourself."))
    }

    @Test func translationRejected() {
        #expect(!permits(
            "please send the report by end of day",
            "Bitte senden Sie den Bericht bis zum Ende des Tages."))
    }

    @Test func continuationRejected() {
        // Model appends invented content — length check catches it even
        // though the prefix reuses raw words.
        #expect(!permits(
            "the meeting is at three",
            "The meeting is at three. Please bring the quarterly slides, the budget forecast, and your laptop."))
    }

    @Test func vocabTermFloodRejected() {
        // Hallucination composed of vocabulary/screen terms must exceed the
        // vocab-credit cap — the screen-term-echo failure mode.
        #expect(!permits(
            "okay let me check that",
            "AppController StreamingDictation ParakeetBackend HistoryStore overlay settings",
            vocab: ["AppController", "StreamingDictation", "ParakeetBackend",
                    "HistoryStore", "overlay", "settings"]))
    }

    @Test func tinyUtteranceCasingPasses() {
        // "hi" -> "Hi." must not trip a bare length ratio — absolute slack.
        #expect(permits("hi", "Hi."))
    }

    @Test func nonSpacedScriptRejects() {
        // Accepted limitation: whitespace tokenization degrades CJK to
        // always-reject (cleanup no-ops there, raw text is delivered).
        #expect(!permits("こんにちは", "今日は天気がいいですね"))
    }
}
