# Cleanup Output Gate (PR A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop LLM cleanup from replacing a correct transcript with hallucinated text — reject any cleanup output that invents words, return the raw transcript, and surface a `rejected` outcome in metrics.

**Architecture:** A pure `CleanupOutputGate` in `PostProcessing` (no FoundationModels import) computes a novel-word ratio between raw and cleaned text; `FoundationModelPostProcessor.cleanup` consults it before accepting model output. A new `LLMCleanupOutcome.rejected` case flows through existing metrics plumbing. The prompt's aggressive "MUST actively transform" opener is softened — the gate is the floor, so anti-echo pressure is no longer needed.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing (NOT XCTest).

**Spec:** `docs/superpowers/specs/2026-07-08-cleanup-gate-parakeet-hybrid-design.md` (Track 1)

## Global Constraints

- Build must stay warning-free: `swift build --arch arm64` (arm64 only, never x86_64).
- Run tests with `swift test` from the repo root (never cd into `.build/checkouts`).
- Swift Testing (`@Test`, `#expect`), not XCTest.
- Invariant: cleanup may improve or no-op, **never lose or invent text** — every rejection/failure path returns the raw transcript.
- `LLMCleanupOutcome` raw values are on-disk schema — never rename existing cases.
- This PR is independent of PR #8; branch from current `main`.

---

### Task 1: `LLMCleanupOutcome.rejected` case + stats plumbing

**Files:**
- Modify: `Sources/FabCore/DictationMetrics.swift` (enum at top of file)
- Modify: `Sources/HistoryStore/HistoryStore.swift` (`CleanupStats` ~line 134, `cleanupStats()` aggregate ~line 387)
- Test: `Tests/HistoryStoreTests/CleanupStatsTests.swift` (existing suite covering `cleanupStats`)

**Interfaces:**
- Consumes: existing `LLMCleanupOutcome` (cases `off`, `unchanged`, `changed`, `fellBack`), `CleanupStats`.
- Produces: `LLMCleanupOutcome.rejected` (raw value `"rejected"`), `CleanupStats.rejectedCount: Int`, extended `CleanupStats.menuSummary`. Task 3 relies on the `.rejected` case existing.

- [ ] **Step 1: Write the failing tests**

In `Tests/HistoryStoreTests/CleanupStatsTests.swift`, add:

```swift
@Test func cleanupStatsCountsRejectedRows() async throws {
    let store = try makeStore()  // reuse the suite's existing in-memory-store helper
    try await insertMetrics(store, llmOutcome: .rejected)   // reuse the suite's insert helper
    try await insertMetrics(store, llmOutcome: .fellBack)
    try await insertMetrics(store, llmOutcome: .changed)
    let stats = try await store.cleanupStats()
    #expect(stats?.rejectedCount == 1)
    #expect(stats?.fellBackCount == 1)
}
```

Adapt helper names to what the suite already uses — do not invent new fixtures if equivalents exist. Also add a `CleanupStats.menuSummary` expectation:

```swift
@Test func cleanupMenuSummaryShowsRejected() {
    let stats = CleanupStats(
        sampleCount: 41, p50LlmMs: 380, p90LlmMs: 710,
        fellBackCount: 2, rejectedCount: 1
    )
    #expect(stats.menuSummary == "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41 · rejected 1/41")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HistoryStoreTests`
Expected: FAIL — `rejectedCount` / `.rejected` not defined.

- [ ] **Step 3: Implement**

`Sources/FabCore/DictationMetrics.swift` — add the case with doc comment:

```swift
    /// The stage failed (throw, timeout, rejected empty output) and the raw
    /// transcript was used — the never-lose-text fallback.
    case fellBack
    /// The model returned output that invented content (failed the
    /// CleanupOutputGate novelty check) and the raw transcript was used —
    /// the never-invent-text fallback.
    case rejected
```

`Sources/HistoryStore/HistoryStore.swift` — `CleanupStats` gains `rejectedCount`:

```swift
public struct CleanupStats: Sendable, Equatable {
    public var sampleCount: Int
    public var p50LlmMs: Double
    public var p90LlmMs: Double
    public var fellBackCount: Int
    public var rejectedCount: Int

    public init(
        sampleCount: Int, p50LlmMs: Double, p90LlmMs: Double,
        fellBackCount: Int, rejectedCount: Int
    ) {
        self.sampleCount = sampleCount
        self.p50LlmMs = p50LlmMs
        self.p90LlmMs = p90LlmMs
        self.fellBackCount = fellBackCount
        self.rejectedCount = rejectedCount
    }

    /// e.g. "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41 · rejected 1/41"
    public var menuSummary: String {
        let p50 = String(format: "%.2f", p50LlmMs / 1000)
        let p90 = String(format: "%.2f", p90LlmMs / 1000)
        return "Cleanup p50 \(p50) s · p90 \(p90) s"
            + " · fell back \(fellBackCount)/\(sampleCount)"
            + " · rejected \(rejectedCount)/\(sampleCount)"
    }
}
```

In `cleanupStats()` (~line 387), add next to the `fellBackCount` computation:

```swift
            fellBackCount: rows.filter { $0.llmOutcome == .fellBack }.count,
            rejectedCount: rows.filter { $0.llmOutcome == .rejected }.count
```

Fix every `CleanupStats(...)` call site the compiler flags (tests included) by adding `rejectedCount:`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HistoryStoreTests && swift test --filter FabCoreTests`
Expected: PASS, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/FabCore/DictationMetrics.swift Sources/HistoryStore/HistoryStore.swift Tests/
git commit -m "feat: LLMCleanupOutcome.rejected case + rejected count in cleanup stats"
```

---

### Task 2: `CleanupOutputGate` pure type + corpus tests

**Files:**
- Create: `Sources/PostProcessing/CleanupOutputGate.swift`
- Test: `Tests/PostProcessingTests/CleanupOutputGateTests.swift`

**Interfaces:**
- Consumes: nothing (pure, Foundation only).
- Produces: `CleanupOutputGate.permits(raw: String, cleaned: String, vocabulary: [String]) -> Bool` — Task 3 calls exactly this.

- [ ] **Step 1: Write the failing corpus tests**

`Tests/PostProcessingTests/CleanupOutputGateTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CleanupOutputGateTests`
Expected: FAIL — `CleanupOutputGate` not defined.

- [ ] **Step 3: Implement the gate**

`Sources/PostProcessing/CleanupOutputGate.swift`:

```swift
import Foundation

/// Accept/reject filter for LLM cleanup output. Pure — no FoundationModels
/// import, fully unit-testable.
///
/// Rationale: legitimate cleanup only *removes* words (fillers, scratch-
/// that), fixes punctuation/casing, and substitutes few words (homophones,
/// vocabulary spellings). Hallucination *invents* words. So: tokenize both
/// texts, count cleaned tokens that never appear in the raw transcript, and
/// reject when too much of the output is novel — or when the output grew
/// beyond what "never add content" allows.
///
/// Tokenization is whitespace-based; non-spaced scripts (CJK) degrade to
/// always-reject, which is safe (cleanup no-ops, raw text is delivered) and
/// accepted for now.
public enum CleanupOutputGate {
    /// Above this share of (uncredited) novel tokens, the output is a
    /// rewrite, not a cleanup. Pinned by CleanupOutputGateTests — change
    /// the corpus before changing the number.
    static let maxNovelRatio = 0.3

    public static func permits(raw: String, cleaned: String, vocabulary: [String]) -> Bool {
        let rawTokens = tokens(raw)
        let cleanedTokens = tokens(cleaned)
        guard !cleanedTokens.isEmpty else { return true }  // empty handled upstream

        // "Never add content", mechanically: absolute slack keeps tiny
        // utterances ("hi" -> "Hi.") from tripping a bare ratio.
        if cleanedTokens.count > rawTokens.count * 3 / 2 + 3 { return false }

        let rawSet = Set(rawTokens)
        let vocabSet = Set(vocabulary.flatMap { tokens($0) })
        var novel = 0
        var vocabNovel = 0
        for token in cleanedTokens where !rawSet.contains(token) {
            if vocabSet.contains(token) {
                vocabNovel += 1
            } else {
                novel += 1
            }
        }
        // Vocabulary substitution is the one sanctioned source of new words,
        // but uncapped credit would wave through a hallucination composed of
        // screen terms — cap it.
        let vocabCredit = min(vocabNovel, max(2, cleanedTokens.count / 10))
        let effectiveNovel = novel + (vocabNovel - vocabCredit)
        return Double(effectiveNovel) / Double(cleanedTokens.count) <= maxNovelRatio
    }

    /// Lowercased words with edge punctuation stripped; interior
    /// apostrophes/hyphens survive ("they're", "day-to-day").
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CleanupOutputGateTests`
Expected: PASS. If a corpus case fails, the fix is in the corpus/threshold trade-off — inspect which side is wrong before touching `maxNovelRatio`; document any threshold change in the test file header comment.

- [ ] **Step 5: Commit**

```bash
git add Sources/PostProcessing/CleanupOutputGate.swift Tests/PostProcessingTests/CleanupOutputGateTests.swift
git commit -m "feat: CleanupOutputGate — novelty check for LLM cleanup output"
```

---

### Task 3: Wire the gate into `FoundationModelPostProcessor`

**Files:**
- Modify: `Sources/PostProcessing/FoundationModelPostProcessor.swift:108-136` (`cleanup`)
- Test: `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift`

**Interfaces:**
- Consumes: `CleanupOutputGate.permits(raw:cleaned:vocabulary:)` (Task 2), `LLMCleanupOutcome.rejected` (Task 1).
- Produces: `cleanup()` returning `CleanupReport(text: raw, outcome: .rejected)` on gate rejection. No signature changes.

- [ ] **Step 1: Write the failing tests**

Add to `FoundationModelPostProcessorTests` (reuse the file's `FakeRequester`/`processor(_:)` helpers):

```swift
    @Test func hallucinatedReplyIsRejectedAndRawKept() async {
        let proc = processor(.reply("Here is a summary of your recent activity."))
        let report = await proc.cleanup("remind me to call the dentist tomorrow")
        #expect(report.text == "remind me to call the dentist tomorrow")
        #expect(report.outcome == .rejected)
    }

    @Test func legitimateCleanupStillPassesGate() async {
        let proc = processor(.reply("So I think we should ship it."))
        let report = await proc.cleanup("um so I think we should uh ship it")
        #expect(report.text == "So I think we should ship it.")
        #expect(report.outcome == .changed)
    }

    @Test func vocabularySubstitutionPassesGate() async {
        let proc = FoundationModelPostProcessor(
            requester: FakeRequester(behavior: .reply("The WhisperKit backend is slow.")),
            vocabulary: ["WhisperKit"]
        )
        let report = await proc.cleanup("the whisper kit backend is slow")
        #expect(report.outcome == .changed)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FoundationModelPostProcessorTests`
Expected: `hallucinatedReplyIsRejectedAndRawKept` FAILS (outcome is `.changed`, text is the hallucination). The other two should already pass — they pin no-regression.

- [ ] **Step 3: Implement**

In `cleanup(_:)`, the merged vocabulary is currently assembled inside `currentInstructions()`. Compute it once and share:

```swift
    public func cleanup(_ text: String) async -> CleanupReport {
        guard !text.isEmpty else {
            return CleanupReport(text: text, outcome: .off)
        }
        let mergedVocabulary = Self.mergedVocabulary(user: vocabulary, screen: screenTerms)
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: mergedVocabulary, appName: appName)
        do {
            let cleaned = try await Self.withTimeout(timeout) { [requester] in
                try await requester.cleanup(instructions: instructions, transcript: text)
            }
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return Self.endsWithScratchThat(text)
                    ? CleanupReport(text: "", outcome: .changed)
                    : CleanupReport(text: text, outcome: .fellBack)
            }
            let stripped = Self.strippingEdgeSpaces(cleaned)
            guard CleanupOutputGate.permits(
                raw: text, cleaned: stripped, vocabulary: mergedVocabulary
            ) else {
                // Never log transcript text — term counts / outcomes only.
                NSLog("fabulous: LLM cleanup output rejected (invented content), using raw transcript")
                return CleanupReport(text: text, outcome: .rejected)
            }
            return CleanupReport(
                text: stripped,
                outcome: stripped == text ? .unchanged : .changed
            )
        } catch {
            NSLog("fabulous: LLM cleanup failed, using raw transcript: \(error)")
            return CleanupReport(text: text, outcome: .fellBack)
        }
    }
```

Keep `currentInstructions()` for `prepare()` — it must keep assembling the instructions EXACTLY the same way (prewarm session matches on exact string), so have it call the same two lines. Update the doc comment on the actor (line 51): "Invariant: may improve or no-op, never lose **or invent** text".

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PostProcessingTests`
Expected: PASS, including the pre-existing scratch-that/timeout/failure tests (the gate must not disturb them).

- [ ] **Step 5: Commit**

```bash
git add Sources/PostProcessing/FoundationModelPostProcessor.swift Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift
git commit -m "feat: gate LLM cleanup output — reject invented content, keep raw"
```

---

### Task 4: Soften the cleanup prompt

**Files:**
- Modify: `Sources/PostProcessing/CleanupPromptBuilder.swift:7-12`
- Test: `Tests/PostProcessingTests/CleanupPromptBuilderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: revised instruction text; `prepare()`/`cleanup()` exact-match invariant unaffected (both build via the same helper after Task 3).

- [ ] **Step 1: Update the prompt-pinning test**

`CleanupPromptBuilderTests` pins the instruction text. Update the expectation for the new opener (adapt to how the test asserts — full-string or contains):

```swift
    @Test func instructionsOpenWithConservativeMandate() {
        let text = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(text.contains("Apply only the rules below"))
        #expect(text.contains("keep it word-for-word"))
        #expect(!text.contains("MUST actively transform"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CleanupPromptBuilderTests`
Expected: FAIL — old opener still present.

- [ ] **Step 3: Implement**

Replace the opening paragraph in `CleanupPromptBuilder.instructions` (keep rules 1–4 and all examples unchanged):

```swift
        var parts: [String] = ["""
        You rewrite dictated speech transcripts. Apply only the rules below; \
        if no rule applies to a part of the text, keep that part word-for-word. \
        Apply exactly these rules:
        ...
```

(`...` = the existing rules 1–4 and examples block, byte-for-byte unchanged.)

- [ ] **Step 4: Run tests, fix any other pinned strings**

Run: `swift test --filter PostProcessingTests`
Expected: PASS. Any other test pinning the old opener gets the same update.

- [ ] **Step 5: Commit**

```bash
git add Sources/PostProcessing/CleanupPromptBuilder.swift Tests/PostProcessingTests/CleanupPromptBuilderTests.swift
git commit -m "feat: soften cleanup prompt — gate replaces anti-echo pressure"
```

---

### Task 5: Full verification + PR

**Files:** none new.

- [ ] **Step 1: Full build + test sweep**

```bash
swift build --arch arm64 && swift test
```
Expected: zero warnings, all tests green (224+ on main).

- [ ] **Step 2: Real-model spot check (optional, macOS 26 + Apple Intelligence)**

Run: `swift test --filter RealFoundationModelTests`
Expected: PASS or skip (availability-gated). Watch for gate rejections on legitimate cleanups in output.

- [ ] **Step 3: Branch + PR**

Work happens on branch `cleanup-output-gate` (create at Task 1 start: `git checkout -b cleanup-output-gate main`). Push and open PR:

```bash
git push -u origin cleanup-output-gate
gh pr create --title "Cleanup output gate: reject hallucinated LLM cleanup" --body "$(cat <<'EOF'
Fixes wrong-text-inserted bug: LLM cleanup accepted any non-empty model
output, so a hallucinating model replaced correct transcripts. Adds
CleanupOutputGate (pure novel-word-ratio check with capped vocabulary
credit), a `rejected` metrics outcome, and a softened prompt opener.

Spec: docs/superpowers/specs/2026-07-08-cleanup-gate-parakeet-hybrid-design.md (Track 1)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
