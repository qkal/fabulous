# LLM Cleanup Observability + Session Prewarm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LLM cleanup latency and outcome measurable per dictation (metrics struct, SQLite, menu bar) and prewarm the `LanguageModelSession` during recording so prompt-processing overlaps speech.

**Architecture:** A new `LLMCleanupOutcome` enum flows from `FoundationModelPostProcessor` (which gains a non-throwing `cleanup(_:) -> CleanupReport` API) through `DictationMetrics` into the `dictationMetrics` table and a new menu line. Prewarm goes the other way: AppController pokes the processor at record-start; the processor assembles instructions and hands them to the requester, which stores one prewarmed session consumed by at most one dictation.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing (NOT XCTest), GRDB (HistoryStore only), FoundationModels (PostProcessing only, macOS 26).

**Spec:** `docs/specs/llm-cleanup-observability.md`

## Global Constraints

- Build: `swift build --arch arm64` — arm64 only, never add x86_64.
- Zero warnings in our targets under strict concurrency; warnings are failures.
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`) — never XCTest.
- Always run swift commands from repo root: `cd /Users/kal/fabulous && swift …` (never cd into `.build/checkouts`).
- Dependency rule: feature modules depend only on FabCore. `PostProcessing` is the only target importing FoundationModels; `HistoryStore` the only one importing GRDB.
- Invariant (spec + CLAUDE.md): LLM cleanup may improve or no-op, never lose text — every failure path returns the raw transcript.
- Invariant: one `LanguageModelSession` serves at most one dictation (no context accumulation, no text leaking across dictations).
- GRDB migration names are append-only and unique; `v4-transcript-rawtext` already exists — the new one is `v5-metrics-llm`.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `LLMCleanupOutcome` + `DictationMetrics` fields (FabCore)

**Files:**
- Modify: `Sources/FabCore/DictationMetrics.swift`
- Test: `Tests/FabCoreTests/DictationMetricsLLMTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on these exact names):
  - `public enum LLMCleanupOutcome: String, Sendable, Codable, Equatable, CaseIterable { case off, unchanged, changed, fellBack }`
  - `DictationMetrics.llmCleanup: Duration` (default `.zero`), `DictationMetrics.llmOutcome: LLMCleanupOutcome` (default `.off`) — both as defaulted init params placed between `transcription` and `postProcessing`.
  - `logLine` gains ` llm=0.42 s (changed)` segment when `llmOutcome != .off`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/DictationMetricsLLMTests.swift`:

```swift
import FabCore
import Testing

@Suite("DictationMetrics LLM stage")
struct DictationMetricsLLMTests {
    private func metrics(
        llmCleanup: Duration = .zero,
        llmOutcome: LLMCleanupOutcome = .off
    ) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 10.4,
            stopAndTrim: .milliseconds(80),
            transcription: .milliseconds(1020),
            llmCleanup: llmCleanup,
            llmOutcome: llmOutcome,
            postProcessing: .milliseconds(3),
            delivery: .milliseconds(180),
            total: .milliseconds(1283)
        )
    }

    @Test func defaultsAreOffAndZero() {
        // Existing callers omit the new params: outcome off, duration zero.
        let m = DictationMetrics(
            audioDuration: 1,
            stopAndTrim: .zero,
            transcription: .zero,
            postProcessing: .zero,
            delivery: .zero,
            total: .zero
        )
        #expect(m.llmOutcome == .off)
        #expect(m.llmCleanup == .zero)
    }

    @Test func logLineOmitsLLMWhenOff() {
        #expect(!metrics().logLine.contains("llm="))
    }

    @Test func logLineShowsLLMStageWhenActive() {
        let line = metrics(
            llmCleanup: .milliseconds(420), llmOutcome: .changed
        ).logLine
        #expect(line.contains("llm=0.42 s (changed)"))
    }

    @Test func rawValuesAreStableForPersistence() {
        // These strings land in SQLite; renaming a case is a schema change.
        #expect(LLMCleanupOutcome.off.rawValue == "off")
        #expect(LLMCleanupOutcome.unchanged.rawValue == "unchanged")
        #expect(LLMCleanupOutcome.changed.rawValue == "changed")
        #expect(LLMCleanupOutcome.fellBack.rawValue == "fellBack")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/kal/fabulous && swift test --filter DictationMetricsLLMTests 2>&1 | tail -20`
Expected: compile FAILURE — `LLMCleanupOutcome` not found, no `llmCleanup` param.

- [ ] **Step 3: Implement**

In `Sources/FabCore/DictationMetrics.swift`, add above the struct:

```swift
/// What the LLM cleanup stage did to one dictation. Persisted by raw value —
/// case names are part of the on-disk schema.
public enum LLMCleanupOutcome: String, Sendable, Codable, Equatable, CaseIterable {
    /// Cleanup disabled or unavailable; the stage never ran.
    case off
    /// The model ran and returned the transcript unmodified.
    case unchanged
    /// The model ran and altered the transcript.
    case changed
    /// The stage failed (throw, timeout, rejected empty output) and the raw
    /// transcript was used — the never-lose-text fallback.
    case fellBack
}
```

In `DictationMetrics`, add stored properties after `transcription`:

```swift
    /// Wall time of the LLM cleanup stage; .zero when the stage was off.
    public var llmCleanup: Duration
    /// What the LLM cleanup stage did (off / unchanged / changed / fellBack).
    public var llmOutcome: LLMCleanupOutcome
```

Extend the init (new params defaulted so existing call sites compile unchanged):

```swift
    public init(
        audioDuration: TimeInterval,
        stopAndTrim: Duration,
        transcription: Duration,
        llmCleanup: Duration = .zero,
        llmOutcome: LLMCleanupOutcome = .off,
        postProcessing: Duration,
        delivery: Duration,
        total: Duration,
        streamed: Bool = false
    ) {
        self.audioDuration = audioDuration
        self.stopAndTrim = stopAndTrim
        self.transcription = transcription
        self.llmCleanup = llmCleanup
        self.llmOutcome = llmOutcome
        self.postProcessing = postProcessing
        self.delivery = delivery
        self.total = total
        self.streamed = streamed
    }
```

In `logLine`, insert the llm segment between the `post=` and `delivery=` parts:

```swift
    public var logLine: String {
        "dictation metrics: total=\(Self.seconds(total))"
            + " stop+vad=\(Self.seconds(stopAndTrim))"
            + " asr=\(Self.seconds(transcription))"
            + (llmOutcome == .off
                ? ""
                : " llm=\(Self.seconds(llmCleanup)) (\(llmOutcome.rawValue))")
            + " post=\(Self.seconds(postProcessing))"
            + " delivery=\(Self.seconds(delivery))"
            + " audio=\(String(format: "%.2f", audioDuration))s"
            + (streamed ? " streamed" : "")
    }
```

`menuSummary` stays untouched (`total` already includes cleanup).

- [ ] **Step 4: Run tests to verify pass (new + existing metrics tests)**

Run: `cd /Users/kal/fabulous && swift test --filter "DictationMetrics" 2>&1 | tail -10`
Expected: PASS, including the pre-existing `DictationMetricsTests` and `DictationMetricsStreamedTests` (they use labeled init params, so the defaults keep them compiling).

- [ ] **Step 5: Commit**

```bash
cd /Users/kal/fabulous && git add Sources/FabCore/DictationMetrics.swift Tests/FabCoreTests/DictationMetricsLLMTests.swift && git commit -m "feat: LLM cleanup stage in DictationMetrics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `CleanupReport` + outcome-reporting `cleanup(_:)` (PostProcessing)

**Files:**
- Modify: `Sources/PostProcessing/FoundationModelPostProcessor.swift`
- Test: `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift` (extend)

**Interfaces:**
- Consumes: `LLMCleanupOutcome` from Task 1 (`import FabCore`).
- Produces:
  - `public struct CleanupReport: Sendable, Equatable { public let text: String; public let outcome: LLMCleanupOutcome; public init(text:outcome:) }`
  - `ContextualTextPostProcessor` gains required `func cleanup(_ text: String) async -> CleanupReport`.
  - `FoundationModelPostProcessor.process` becomes `await cleanup(text).text` (still the never-lose-text floor; it never throws in practice).
  - Note: `FoundationModelPostProcessor` is the ONLY conformer of `ContextualTextPostProcessor` in the repo (verified) — no other type needs updating.

- [ ] **Step 1: Write the failing tests**

Append to the `FoundationModelPostProcessorTests` struct in `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift` (the file already has the `FakeRequester` fake and the `processor(_:timeout:)` helper — reuse them; also add `import FabCore` if not present, it is already imported):

```swift
    // MARK: - CleanupReport outcomes

    @Test func reportChangedWhenModelRewrites() async {
        let p = processor(.reply("Ship it."))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "Ship it.", outcome: .changed))
    }

    @Test func reportUnchangedWhenModelEchoes() async {
        let p = processor(.reply("um ship it"))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .unchanged))
    }

    @Test func reportUnchangedComparesAfterEdgeStrip() async {
        // Model echoed with stray edge spaces: text is stripped, still a no-op.
        let p = processor(.reply("  um ship it "))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .unchanged))
    }

    @Test func reportFellBackOnError() async {
        let p = processor(.fail)
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .fellBack))
    }

    @Test func reportFellBackOnTimeout() async {
        let p = processor(.hang, timeout: .milliseconds(50))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .fellBack))
    }

    @Test func reportFellBackOnRejectedEmptyOutput() async {
        let p = processor(.reply("  \n"))
        let report = await p.cleanup("hello world")
        #expect(report == CleanupReport(text: "hello world", outcome: .fellBack))
    }

    @Test func reportChangedOnLegitimateScratchToEmpty() async {
        let p = processor(.reply(""))
        let report = await p.cleanup("blah blah scratch that")
        #expect(report == CleanupReport(text: "", outcome: .changed))
    }

    @Test func reportUnchangedOnEmptyInput() async {
        let p = processor(.fail) // would throw if the model were called
        let report = await p.cleanup("")
        #expect(report == CleanupReport(text: "", outcome: .unchanged))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter FoundationModelPostProcessorTests 2>&1 | tail -20`
Expected: compile FAILURE — no `CleanupReport`, no `cleanup(_:)` on the processor.

- [ ] **Step 3: Implement**

In `Sources/PostProcessing/FoundationModelPostProcessor.swift`:

Add after the imports:

```swift
/// What the cleanup stage produced and what it did — the outcome feeds
/// DictationMetrics so fallbacks are distinguishable from no-ops.
public struct CleanupReport: Sendable, Equatable {
    public let text: String
    public let outcome: LLMCleanupOutcome

    public init(text: String, outcome: LLMCleanupOutcome) {
        self.text = text
        self.outcome = outcome
    }
}
```

Extend the protocol:

```swift
public protocol ContextualTextPostProcessor: TextPostProcessor {
    func setAppContext(name: String?) async
    /// Non-throwing cleanup with outcome reporting. Implementations must
    /// uphold the invariant: every failure returns the input text.
    func cleanup(_ text: String) async -> CleanupReport
}
```

Replace `FoundationModelPostProcessor.process` with:

```swift
    public func process(_ text: String) async throws -> String {
        await cleanup(text).text
    }

    public func cleanup(_ text: String) async -> CleanupReport {
        guard !text.isEmpty else {
            return CleanupReport(text: text, outcome: .unchanged)
        }
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: vocabulary, appName: appName
        )
        do {
            let cleaned = try await Self.withTimeout(timeout) { [requester] in
                try await requester.cleanup(instructions: instructions, transcript: text)
            }
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // "blah blah scratch that" legitimately cleans to nothing;
                // empty output on anything else is a model failure.
                return Self.endsWithScratchThat(text)
                    ? CleanupReport(text: "", outcome: .changed)
                    : CleanupReport(text: text, outcome: .fellBack)
            }
            let stripped = Self.strippingEdgeSpaces(cleaned)
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

(The old `process` body is gone; everything else — `endsWithScratchThat`, `strippingEdgeSpaces`, `withTimeout` — stays.)

- [ ] **Step 4: Run tests to verify pass**

Run: `cd /Users/kal/fabulous && swift test --filter PostProcessingTests 2>&1 | tail -10`
Expected: PASS — all pre-existing `process`-based tests still green (process delegates to cleanup), all new report tests green.

- [ ] **Step 5: Commit**

```bash
cd /Users/kal/fabulous && git add Sources/PostProcessing/FoundationModelPostProcessor.swift Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift && git commit -m "feat: cleanup outcome reporting via CleanupReport

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Prewarm seams + prepared-session store (PostProcessing)

**Files:**
- Create: `Sources/PostProcessing/PreparedSession.swift`
- Modify: `Sources/PostProcessing/FoundationModelPostProcessor.swift` (protocol additions + processor `prepare()`)
- Modify: `Sources/PostProcessing/FoundationModelRequester.swift` (struct → actor, prepared-session use)
- Test: `Tests/PostProcessingTests/PreparedSessionTests.swift` (create)
- Test: `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift` (extend)

**Interfaces:**
- Consumes: `CleanupPromptBuilder.instructions(vocabulary:appName:)` (existing), `CleanupResult` `@Generable` (existing in FoundationModelRequester.swift).
- Produces:
  - `LanguageModelRequesting` gains `func prepare(instructions: String) async` with protocol-extension default no-op (existing fakes compile unchanged).
  - `ContextualTextPostProcessor` gains `func prepare() async` with protocol-extension default no-op.
  - `struct PreparedSession<Session>` (internal to PostProcessing): `mutating func store(_ session: Session, instructions: String)`, `mutating func take(matching instructions: String) -> Session?` — take ALWAYS clears.
  - `FoundationModelRequester` becomes an `actor` (its `LanguageModelSession` state must be isolation-confined; same pattern as `WhisperKitBackend`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PostProcessingTests/PreparedSessionTests.swift`:

```swift
@testable import PostProcessing
import Testing

@Suite("PreparedSession")
struct PreparedSessionTests {
    @Test func matchingTakeReturnsSessionOnce() {
        var box = PreparedSession<Int>()
        box.store(7, instructions: "abc")
        #expect(box.take(matching: "abc") == 7)
        // Consumed: a prepared session serves at most one dictation.
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func mismatchedTakeReturnsNilAndDiscards() {
        var box = PreparedSession<Int>()
        box.store(7, instructions: "abc")
        // Focus change / vocab edit between record-start and stop → stale.
        #expect(box.take(matching: "different") == nil)
        // The stale session is gone, not resurrected for a later match.
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func emptyTakeReturnsNil() {
        var box = PreparedSession<Int>()
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func storeReplacesPrevious() {
        var box = PreparedSession<Int>()
        box.store(1, instructions: "old")
        box.store(2, instructions: "new")
        #expect(box.take(matching: "old") == nil)
    }
}
```

Note the second `take` in `storeReplacesPrevious` would clear anyway; asserting the "old" miss is the point.

Append to `FoundationModelPostProcessorTests.swift` — a recording fake plus prepare-forwarding tests (place the fake at file scope, next to `FakeRequester`):

```swift
/// Records the instruction strings handed to prepare/cleanup.
private actor RecordingRequester: LanguageModelRequesting {
    private(set) var preparedInstructions: [String] = []
    private(set) var cleanedInstructions: [String] = []

    func prepare(instructions: String) async {
        preparedInstructions.append(instructions)
    }

    func cleanup(instructions: String, transcript: String) async throws -> String {
        cleanedInstructions.append(instructions)
        return transcript
    }
}
```

And inside the test struct:

```swift
    // MARK: - Prewarm

    @Test func prepareForwardsExactCleanupInstructions() async throws {
        let requester = RecordingRequester()
        let p = FoundationModelPostProcessor(
            requester: requester, vocabulary: ["WhisperKit"]
        )
        await p.setAppContext(name: "Notes")
        await p.prepare()
        _ = await p.cleanup("hello")
        let prepared = await requester.preparedInstructions
        let cleaned = await requester.cleanedInstructions
        // The prewarmed instructions must be byte-identical to what cleanup
        // sends, or the real requester discards the warmed session.
        #expect(prepared == cleaned)
        #expect(prepared.count == 1)
    }

    @Test func defaultPrepareIsANoOp() async throws {
        // FakeRequester doesn't implement prepare(instructions:) — the
        // protocol-extension default keeps existing requester fakes
        // source-compatible, and the processor's prepare() tolerates it.
        let p = processor(.reply("x"))
        await p.prepare()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter PostProcessingTests 2>&1 | tail -20`
Expected: compile FAILURE — no `PreparedSession`, no `prepare` requirements.

- [ ] **Step 3: Implement**

Create `Sources/PostProcessing/PreparedSession.swift`:

```swift
/// Holds at most one prewarmed model session keyed by its instructions.
/// `take` always clears the slot — matched or not — so a prepared session
/// can serve at most one dictation. That is the fresh-session-per-dictation
/// invariant (no context accumulation, no text leaking across dictations)
/// enforced by construction. Generic so tests cover the consume-once
/// semantics without FoundationModels.
struct PreparedSession<Session> {
    private var stored: (instructions: String, session: Session)?

    mutating func store(_ session: Session, instructions: String) {
        stored = (instructions, session)
    }

    /// Returns the session only when `instructions` match what it was
    /// prepared with; either way the slot is emptied.
    mutating func take(matching instructions: String) -> Session? {
        defer { stored = nil }
        guard let stored, stored.instructions == instructions else { return nil }
        return stored.session
    }
}
```

In `Sources/PostProcessing/FoundationModelPostProcessor.swift`, extend both protocols and add defaults:

```swift
public protocol LanguageModelRequesting: Sendable {
    func cleanup(instructions: String, transcript: String) async throws -> String
    /// Optional prewarm hook: build/warm a session for these instructions
    /// ahead of the cleanup call. Best-effort — failures must be swallowed.
    func prepare(instructions: String) async
}

extension LanguageModelRequesting {
    public func prepare(instructions: String) async {}
}
```

```swift
public protocol ContextualTextPostProcessor: TextPostProcessor {
    func setAppContext(name: String?) async
    func cleanup(_ text: String) async -> CleanupReport
    /// Optional prewarm hook, called at record-start so model warm-up
    /// overlaps the user speaking.
    func prepare() async
}

extension ContextualTextPostProcessor {
    public func prepare() async {}
}
```

Add to `FoundationModelPostProcessor` (after `setAppContext`):

```swift
    public func prepare() async {
        // Must assemble the instructions EXACTLY as cleanup() does — the
        // requester only uses the warmed session on an exact match.
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: vocabulary, appName: appName
        )
        await requester.prepare(instructions: instructions)
    }
```

Rewrite `Sources/PostProcessing/FoundationModelRequester.swift` — the type becomes an actor holding the prepared slot (keep the `CleanupResult` `@Generable` struct and the static `prewarm()` as they are):

```swift
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
```

- [ ] **Step 4: Run tests + full build**

Run: `cd /Users/kal/fabulous && swift test --filter PostProcessingTests 2>&1 | tail -10 && swift build --arch arm64 2>&1 | tail -5`
Expected: tests PASS; build succeeds with zero warnings (the struct→actor change is source-compatible for AppController, which already calls the requester only through async protocol methods).

- [ ] **Step 5: Commit**

```bash
cd /Users/kal/fabulous && git add Sources/PostProcessing/ Tests/PostProcessingTests/ && git commit -m "feat: prewarm LanguageModelSession during recording

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Persistence + cleanup stats (HistoryStore)

**Files:**
- Modify: `Sources/HistoryStore/HistoryStore.swift`
- Test: `Tests/HistoryStoreTests/CleanupStatsTests.swift` (create)

**Interfaces:**
- Consumes: `LLMCleanupOutcome` (Task 1; HistoryStore already imports FabCore — verify, add `import FabCore` if missing).
- Produces:
  - `MetricsEntry.llmMs: Double` (init default `0`), `MetricsEntry.llmOutcome: LLMCleanupOutcome` (init default `.off`) — GRDB's Codable support stores the enum as its raw-value TEXT.
  - Migration `v5-metrics-llm`.
  - `public struct CleanupStats: Sendable, Equatable { sampleCount: Int; p50LlmMs: Double; p90LlmMs: Double; fellBackCount: Int; var menuSummary: String }`
  - `public func cleanupStats(limit: Int = 500) throws -> CleanupStats?` — engine-agnostic, newest `limit` rows with outcome ≠ off, nil when none.

- [ ] **Step 1: Write the failing tests**

Create `Tests/HistoryStoreTests/CleanupStatsTests.swift`:

```swift
import FabCore
import Foundation
import HistoryStore
import Testing

@Suite("Cleanup stats")
struct CleanupStatsTests {
    private func entry(
        llmMs: Double, llmOutcome: LLMCleanupOutcome, at date: Date
    ) -> MetricsEntry {
        MetricsEntry(
            createdAt: date,
            engineID: "large-v3_turbo",
            audioSeconds: 5,
            stopTrimMs: 50,
            asrMs: 900,
            postMs: 2,
            deliveryMs: 150,
            totalMs: 1500,
            llmMs: llmMs,
            llmOutcome: llmOutcome
        )
    }

    @Test func nilWhenNoLLMRows() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(llmMs: 0, llmOutcome: .off, at: Date()))
        #expect(try store.cleanupStats() == nil)
    }

    @Test func excludesOffRowsAndCountsFallbacks() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.recordMetrics(entry(llmMs: 0, llmOutcome: .off, at: base))
        try store.recordMetrics(entry(llmMs: 300, llmOutcome: .changed, at: base.addingTimeInterval(1)))
        try store.recordMetrics(entry(llmMs: 500, llmOutcome: .unchanged, at: base.addingTimeInterval(2)))
        try store.recordMetrics(entry(llmMs: 700, llmOutcome: .fellBack, at: base.addingTimeInterval(3)))

        let stats = try #require(try store.cleanupStats())
        #expect(stats.sampleCount == 3)
        #expect(stats.fellBackCount == 1)
        #expect(stats.p50LlmMs == 500)
        #expect(stats.p90LlmMs == 700)
    }

    @Test func limitBoundsTheWindow() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<4 {
            try store.recordMetrics(entry(
                llmMs: Double(100 * (i + 1)), llmOutcome: .changed,
                at: base.addingTimeInterval(Double(i))
            ))
        }
        // Newest 2 rows only: 300 and 400 ms.
        let stats = try #require(try store.cleanupStats(limit: 2))
        #expect(stats.sampleCount == 2)
        #expect(stats.p50LlmMs == 300)
    }

    @Test func menuSummaryFormat() {
        let stats = CleanupStats(
            sampleCount: 41, p50LlmMs: 380, p90LlmMs: 710, fellBackCount: 2
        )
        #expect(stats.menuSummary == "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41")
    }

    @Test func outcomePersistsAsRawValueText() throws {
        // The column is TEXT holding the enum raw value — pinned so a case
        // rename can't silently corrupt old rows.
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(llmMs: 1, llmOutcome: .fellBack, at: Date()))
        let raw = try store.rawLLMOutcomes()
        #expect(raw == ["fellBack"])
    }

    @Test func oldRowsReadBackAsOff() throws {
        // Rows inserted before v5 (simulated via default params) must read
        // back as off/0 — the migration defaults.
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(MetricsEntry(
            createdAt: Date(), engineID: "e", audioSeconds: 1,
            stopTrimMs: 1, asrMs: 1, postMs: 1, deliveryMs: 1, totalMs: 5
        ))
        let stats = try store.cleanupStats()
        #expect(stats == nil)
    }
}
```

Also add this small test hook to `HistoryStore` (it justifies itself: pins the on-disk representation without exposing GRDB to callers). It goes in the implementation step, but the test above references it: `rawLLMOutcomes()`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter CleanupStatsTests 2>&1 | tail -20`
Expected: compile FAILURE — `MetricsEntry` has no `llmMs`/`llmOutcome`, no `CleanupStats`.

- [ ] **Step 3: Implement**

In `Sources/HistoryStore/HistoryStore.swift` (file already imports FabCore via `import FabCore`? — check the imports at the top; if only `import GRDB`/`Foundation`, add `import FabCore`):

`MetricsEntry` — add after `streamed`:

```swift
    /// Wall time of the LLM cleanup stage in milliseconds; 0 when off.
    public var llmMs: Double
    /// What the cleanup stage did; stored as the enum's raw-value text.
    public var llmOutcome: LLMCleanupOutcome
```

Extend its init with defaulted trailing params (existing call sites compile unchanged):

```swift
        streamed: Bool = false,
        llmMs: Double = 0,
        llmOutcome: LLMCleanupOutcome = .off
    ) {
        ...
        self.streamed = streamed
        self.llmMs = llmMs
        self.llmOutcome = llmOutcome
    }
```

Migration — append after `v4-transcript-rawtext` (names are append-only; v4 is taken):

```swift
        migrator.registerMigration("v5-metrics-llm") { db in
            try db.alter(table: MetricsEntry.databaseTableName) { t in
                t.add(column: "llmMs", .double).notNull().defaults(to: 0)
                t.add(column: "llmOutcome", .text).notNull()
                    .defaults(to: LLMCleanupOutcome.off.rawValue)
            }
        }
```

`CleanupStats` — add next to `LatencyStats`:

```swift
/// LLM cleanup latency/reliability over recent dictations (all engines —
/// the cleanup model is engine-independent).
public struct CleanupStats: Sendable, Equatable {
    public var sampleCount: Int
    public var p50LlmMs: Double
    public var p90LlmMs: Double
    public var fellBackCount: Int

    public init(
        sampleCount: Int, p50LlmMs: Double, p90LlmMs: Double, fellBackCount: Int
    ) {
        self.sampleCount = sampleCount
        self.p50LlmMs = p50LlmMs
        self.p90LlmMs = p90LlmMs
        self.fellBackCount = fellBackCount
    }

    /// e.g. "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41"
    public var menuSummary: String {
        let p50 = String(format: "%.2f", p50LlmMs / 1000)
        let p90 = String(format: "%.2f", p90LlmMs / 1000)
        return "Cleanup p50 \(p50) s · p90 \(p90) s"
            + " · fell back \(fellBackCount)/\(sampleCount)"
    }
}
```

Query + raw hook — add in the `// MARK: - Dictation metrics` section, after `latencyStats`:

```swift
    /// Cleanup p50/p90 and fallback count over the newest `limit` dictations
    /// where the LLM stage ran; nil when it never has.
    public func cleanupStats(limit: Int = 500) throws -> CleanupStats? {
        let rows = try dbQueue.read { db in
            try MetricsEntry
                .filter(Column("llmOutcome") != LLMCleanupOutcome.off.rawValue)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        guard !rows.isEmpty else { return nil }
        let times = rows.map(\.llmMs).sorted()
        return CleanupStats(
            sampleCount: rows.count,
            p50LlmMs: Self.percentile(times, 0.5),
            p90LlmMs: Self.percentile(times, 0.9),
            fellBackCount: rows.count { $0.llmOutcome == .fellBack }
        )
    }

    /// Raw llmOutcome column values, newest first — pins the on-disk
    /// representation in tests.
    public func rawLLMOutcomes() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT llmOutcome FROM dictationMetrics ORDER BY createdAt DESC, id DESC"
            )
        }
    }
```

(If `rows.count { ... }` doesn't compile on the toolchain, use `rows.filter { $0.llmOutcome == .fellBack }.count`.)

- [ ] **Step 4: Run HistoryStore tests (new + existing)**

Run: `cd /Users/kal/fabulous && swift test --filter HistoryStoreTests 2>&1 | tail -10 && swift test --filter CleanupStatsTests 2>&1 | tail -10 && swift test --filter MigrationProbeTests 2>&1 | tail -10`
Expected: all PASS — existing metrics tests compile via the defaulted params; the migration probe still passes with v5 appended.

- [ ] **Step 5: Commit**

```bash
cd /Users/kal/fabulous && git add Sources/HistoryStore/HistoryStore.swift Tests/HistoryStoreTests/CleanupStatsTests.swift && git commit -m "feat: persist LLM cleanup metrics + cleanup stats query

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: App wiring — timing, menu line, prewarm trigger (FabulousApp)

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift` (finishRecording ~lines 500–545, beginRecording ~line 370, persistMetrics ~line 621, refreshLatencyStats ~line 645)
- Modify: `Sources/FabulousApp/StatusItemController.swift` (new menu item + setter)

No unit tests: FabulousApp is the executable target (not importable from tests); all logic added here is one-line glue over the tested seams from Tasks 1–4. Verification is compile + full suite + a manual dogfood pass.

**Interfaces:**
- Consumes: `llmProcessor.cleanup(_:) -> CleanupReport`, `llmProcessor.prepare()`, `DictationMetrics(llmCleanup:llmOutcome:)`, `MetricsEntry(llmMs:llmOutcome:)`, `history.cleanupStats()`, `CleanupStats.menuSummary`.
- Produces: `StatusItemController.setCleanupStats(_ summary: String?)`.

- [ ] **Step 1: StatusItemController — cleanup stats menu line**

In `Sources/FabulousApp/StatusItemController.swift`:

Add the item declaration after `statsItem` (line ~11):

```swift
    private let cleanupStatsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
```

In `install`, configure it next to `statsItem` (after line ~50):

```swift
        cleanupStatsItem.isEnabled = false
        cleanupStatsItem.isHidden = true // until an LLM-cleaned dictation exists
```

Add it to `menu.items` directly after `statsItem`:

```swift
        menu.items = [
            stateItem,
            hintItem,
            metricsItem,
            statsItem,
            cleanupStatsItem,
            .separator(),
            copyItem,
            settingsItem,
            setupItem,
            .separator(),
            quitItem,
        ]
```

Add the setter next to `setLatencyStats` (line ~126):

```swift
    /// LLM cleanup p50/p90 + fallback line under the latency line; nil hides
    /// it (cleanup never ran, or metrics store unavailable).
    func setCleanupStats(_ summary: String?) {
        cleanupStatsItem.title = summary ?? ""
        cleanupStatsItem.isHidden = summary == nil
    }
```

- [ ] **Step 2: AppController — prewarm at record-start**

In `beginRecording()` (line ~370), directly after `recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier`:

```swift
            // Warm the cleanup session while the user speaks: the session
            // and its instructions prefix are ready when transcription ends.
            // Fire-and-forget — prewarm is opportunistic, never blocking.
            if let llmProcessor {
                Task {
                    await llmProcessor.setAppContext(name: recordingTargetAppName())
                    await llmProcessor.prepare()
                }
            }
```

- [ ] **Step 3: AppController — outcome-reporting cleanup call + stage timing**

In `finishRecording()`, replace the block from `var cleaned = rawText` through `let llmChangedText = cleaned != rawText` (lines ~502–516) with:

```swift
            var cleaned = rawText
            var llmOutcome = LLMCleanupOutcome.off
            // The model may have become available since launch (e.g. it was
            // still downloading) — cheap re-check so cleanup doesn't stay
            // dead until restart.
            if llmProcessor == nil, settings.llmCleanupEnabled {
                rebuildLLMProcessor()
            }
            if let llmProcessor {
                await llmProcessor.setAppContext(name: recordingTargetAppName())
                let report = await llmProcessor.cleanup(rawText)
                cleaned = report.text
                llmOutcome = report.outcome
            }
            let llmDoneAt = clock.now
            let text = try await postProcessor.process(cleaned)
            let processedAt = clock.now
```

Then in `recordHistory` (line ~524), the rawText argument keys off the outcome (single source of truth with metrics):

```swift
            recordHistory(
                text: text,
                rawText: llmOutcome == .changed ? rawText : nil,
                audioSeconds: transcript.audioDuration ?? audio.duration
            )
```

And the `noteMetrics` call (line ~534) gains the two stage fields — `postProcessing` now measures replacements only:

```swift
            noteMetrics(DictationMetrics(
                audioDuration: transcript.audioDuration ?? audio.duration,
                stopAndTrim: stoppedAt - releasedAt,
                transcription: transcribedAt - stoppedAt,
                llmCleanup: llmOutcome == .off ? .zero : llmDoneAt - transcribedAt,
                llmOutcome: llmOutcome,
                postProcessing: processedAt - llmDoneAt,
                delivery: deliveredAt - processedAt,
                total: deliveredAt - releasedAt,
                streamed: streamed
            ))
```

- [ ] **Step 4: AppController — persist + refresh the menu line**

In `persistMetrics` (line ~621), extend the `MetricsEntry` and refresh the cleanup line after the latency line:

```swift
            try history.recordMetrics(MetricsEntry(
                createdAt: Date(),
                engineID: engineID,
                audioSeconds: metrics.audioDuration,
                stopTrimMs: DictationMetrics.milliseconds(metrics.stopAndTrim),
                asrMs: DictationMetrics.milliseconds(metrics.transcription),
                postMs: DictationMetrics.milliseconds(metrics.postProcessing),
                deliveryMs: DictationMetrics.milliseconds(metrics.delivery),
                totalMs: DictationMetrics.milliseconds(metrics.total),
                streamed: metrics.streamed,
                llmMs: DictationMetrics.milliseconds(metrics.llmCleanup),
                llmOutcome: metrics.llmOutcome
            ))
            let stats = try history.latencyStats(engineID: engineID)
            statusItem.setLatencyStats(stats.map { Self.statsSummary($0, engineID: engineID) })
            let cleanupStats = try history.cleanupStats()
            statusItem.setCleanupStats(cleanupStats?.menuSummary)
```

In `refreshLatencyStats` (line ~645), mirror it:

```swift
    private func refreshLatencyStats() {
        guard let history, let engineID = activeModelID else { return }
        let stats = try? history.latencyStats(engineID: engineID)
        statusItem.setLatencyStats(stats.map { Self.statsSummary($0, engineID: engineID) })
        let cleanupStats = (try? history.cleanupStats()) ?? nil
        statusItem.setCleanupStats(cleanupStats?.menuSummary)
    }
```

(`try?` on an Optional-returning throwing call yields `Double Optional` — the `?? nil` flattens it.)

- [ ] **Step 5: Build + full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: build succeeds with zero warnings in our targets; full suite PASSES. If the compiler flags the fire-and-forget `Task` capture in beginRecording, capture explicitly: `Task { [llmProcessor] in ... }` — `llmProcessor` is already unwrapped as a local `let` by the `if let`, which is Sendable-safe (it's an `any ContextualTextPostProcessor`, an actor).

- [ ] **Step 6: Commit**

```bash
cd /Users/kal/fabulous && git add Sources/FabulousApp/AppController.swift Sources/FabulousApp/StatusItemController.swift && git commit -m "feat: cleanup metrics in menu + prewarm at record-start

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Manual dogfood check (app bundle)**

Run: `cd /Users/kal/fabulous && scripts/build.sh && open build/fabulous.app`
(If codesign fails with `errSecInternalComponent`, the dev keychain locked: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db` and retry.)

With LLM cleanup enabled in Settings → General, dictate twice, then check:
- Menu shows `Cleanup p50 … · p90 … · fell back 0/2` under the engine stats line.
- Console log line contains `llm=… (changed)` or `(unchanged)`.
- History tab still shows raw + cleaned when the text changed.
- With cleanup disabled: no cleanup menu line growth (rows record `off` and are excluded), log has no `llm=` segment.

---

## Verification (post-plan)

Full suite + zero-warning build already gated per task. The prewarm latency delta is deliberately NOT asserted in tests (spec: measured manually during dogfood via menu p50/p90 before/after this change).
