# LLM Post-Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optional on-device LLM pass (Apple Foundation Models) that cleans dictated text — fillers, punctuation, spoken commands, vocabulary bias — before injection, off by default.

**Architecture:** New SwiftPM target `PostProcessing` (depends on FabCore only, sole importer of FoundationModels) implements the existing `TextPostProcessor` seam. `AppController` runs the LLM stage before the replacement dictionary, records raw text into history when the LLM changed it. The keystroke injection strategy learns to type Return for `\n`. Spec: `docs/specs/llm-post-processing.md`.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing (NOT XCTest), FoundationModels (macOS 26), GRDB.

## Global Constraints

- Build: `cd /Users/kal/fabulous && swift build --arch arm64` — never add x86_64, never cd into `.build/checkouts`.
- Test: `cd /Users/kal/fabulous && swift test` (Swift Testing: `@Test`, `#expect`, `@Suite` — not XCTest).
- Zero warnings in our targets under strict concurrency. Warnings are failures.
- Package platform floor stays `.macOS(.v14)`. ALL FoundationModels code gated `@available(macOS 26.0, *)` (pattern: `Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift`).
- Dependency rule: `PostProcessing` depends on FabCore only. Only FabulousApp sees everything.
- No .xcodeproj. Ever.
- Invariant: LLM stage may improve or no-op, never lose text. Any failure → raw text through.
- FoundationModels API names in this plan (`SystemLanguageModel`, `LanguageModelSession`, `@Generable`, `@Guide`, `GenerationOptions`, `respond(to:generating:options:)`) are from the macOS 26 SDK. If the compiler rejects an exact name/case, consult the SDK headers and adapt the call site only — do not change protocol seams or test contracts.
- Commit after every task (subject ≤ 50 chars, conventional commits).

---

### Task 1: PostProcessing target + CleanupPromptBuilder

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PostProcessing/CleanupPromptBuilder.swift`
- Test: `Tests/PostProcessingTests/CleanupPromptBuilderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `CleanupPromptBuilder.instructions(vocabulary: [String], appName: String?) -> String` — used by Task 2 (processor) and Task 3 (real requester prompt path).

- [ ] **Step 1: Add target + test target to Package.swift**

In `Package.swift`, after the `HistoryStore` target entry, add:

```swift
        // On-device LLM transcript cleanup (Apple Foundation Models,
        // macOS 26). The only target importing FoundationModels.
        .target(name: "PostProcessing", dependencies: ["FabCore"]),
```

Add `"PostProcessing"` to the `FabulousApp` executable target's dependencies array (after `"HistoryStore"`).

After the `TranscriptionEngineTests` test target line, add:

```swift
        .testTarget(name: "PostProcessingTests", dependencies: ["PostProcessing"]),
```

- [ ] **Step 2: Write the failing test**

Create `Tests/PostProcessingTests/CleanupPromptBuilderTests.swift`:

```swift
import PostProcessing
import Testing

struct CleanupPromptBuilderTests {
    @Test func containsCoreCleanupRules() {
        let instructions = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(instructions.contains("filler"))
        #expect(instructions.contains("new paragraph"))
        #expect(instructions.contains("scratch that"))
        #expect(instructions.contains("quote"))
        #expect(instructions.contains("Never add content"))
    }

    @Test func vocabularyListedWhenPresent() {
        let instructions = CleanupPromptBuilder.instructions(
            vocabulary: ["Anthropic", "WhisperKit"], appName: nil
        )
        #expect(instructions.contains("Anthropic"))
        #expect(instructions.contains("WhisperKit"))
    }

    @Test func vocabularySectionOmittedWhenEmpty() {
        let instructions = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(!instructions.contains("Prefer these spellings"))
    }

    @Test func appHintPresentOnlyWhenKnown() {
        let with = CleanupPromptBuilder.instructions(vocabulary: [], appName: "Xcode")
        let without = CleanupPromptBuilder.instructions(vocabulary: [], appName: nil)
        #expect(with.contains("Xcode"))
        #expect(!without.contains("destined for"))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/kal/fabulous && swift test --filter CleanupPromptBuilderTests`
Expected: FAIL — `no such module 'PostProcessing'` or `cannot find 'CleanupPromptBuilder'`.

- [ ] **Step 4: Implement CleanupPromptBuilder**

Create `Sources/PostProcessing/CleanupPromptBuilder.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter CleanupPromptBuilderTests`
Expected: 4 tests PASS. Also run `swift build --arch arm64` — zero warnings.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PostProcessing Tests/PostProcessingTests
git commit -m "feat: PostProcessing target + cleanup prompt builder"
```

---

### Task 2: FoundationModelPostProcessor (fallback logic, fake-backed)

**Files:**
- Create: `Sources/PostProcessing/FoundationModelPostProcessor.swift`
- Test: `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift`

**Interfaces:**
- Consumes: `CleanupPromptBuilder.instructions(vocabulary:appName:)` (Task 1); `FabCore.TextPostProcessor` (`func process(_ text: String) async throws -> String`).
- Produces:
  - `protocol ContextualTextPostProcessor: TextPostProcessor { func setAppContext(name: String?) async }` — AppController stores the LLM stage as this (Task 6).
  - `protocol LanguageModelRequesting: Sendable { func cleanup(instructions: String, transcript: String) async throws -> String }` — Task 3 implements with the real model.
  - `actor FoundationModelPostProcessor: ContextualTextPostProcessor`, `init(requester: any LanguageModelRequesting, vocabulary: [String], timeout: Duration = .seconds(3))`.
  - `FoundationModelPostProcessor.containsCommandPhrase(_ text: String) -> Bool` (static, internal-visible for tests via `@testable`? No — make it `public static`; PipelineTests never needs it, tests here use the public API).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift`:

```swift
import FabCore
import Foundation
import PostProcessing
import Testing

/// Scriptable fake model.
private struct FakeRequester: LanguageModelRequesting {
    enum Behavior: Sendable {
        case reply(String)
        case fail
        case hang
    }
    let behavior: Behavior

    func cleanup(instructions: String, transcript: String) async throws -> String {
        switch behavior {
        case let .reply(text): return text
        case .fail: throw CocoaError(.featureUnsupported)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return transcript
        }
    }
}

struct FoundationModelPostProcessorTests {
    private func processor(
        _ behavior: FakeRequester.Behavior,
        timeout: Duration = .seconds(3)
    ) -> FoundationModelPostProcessor {
        FoundationModelPostProcessor(
            requester: FakeRequester(behavior: behavior),
            vocabulary: [],
            timeout: timeout
        )
    }

    @Test func successReturnsCleanedText() async throws {
        let p = processor(.reply("Ship it."))
        #expect(try await p.process("um ship it") == "Ship it.")
    }

    @Test func modelErrorFallsBackToRawText() async throws {
        let p = processor(.fail)
        #expect(try await p.process("um ship it") == "um ship it")
    }

    @Test func timeoutFallsBackToRawText() async throws {
        let p = processor(.hang, timeout: .milliseconds(50))
        #expect(try await p.process("um ship it") == "um ship it")
    }

    @Test func emptyOutputWithoutCommandFallsBackToRawText() async throws {
        let p = processor(.reply("  \n"))
        #expect(try await p.process("hello world") == "hello world")
    }

    @Test func emptyOutputWithScratchThatIsAccepted() async throws {
        let p = processor(.reply(""))
        #expect(try await p.process("blah blah scratch that") == "")
    }

    @Test func emptyInputSkipsModel() async throws {
        let p = processor(.fail) // would throw if called
        #expect(try await p.process("") == "")
    }

    @Test func commandPhraseDetection() {
        #expect(FoundationModelPostProcessor.containsCommandPhrase("blah Scratch That"))
        #expect(!FoundationModelPostProcessor.containsCommandPhrase("hello world"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter FoundationModelPostProcessorTests`
Expected: FAIL — `cannot find type 'LanguageModelRequesting'`.

- [ ] **Step 3: Implement the processor**

Create `Sources/PostProcessing/FoundationModelPostProcessor.swift`:

```swift
import FabCore
import Foundation

/// A post-processor whose prompt depends on per-dictation context
/// (the injection target app). AppController sets the context right
/// before running the pipeline.
public protocol ContextualTextPostProcessor: TextPostProcessor {
    func setAppContext(name: String?) async
}

/// Seam over the language model so fallback behavior is testable
/// without Apple Intelligence.
public protocol LanguageModelRequesting: Sendable {
    func cleanup(instructions: String, transcript: String) async throws -> String
}

/// LLM cleanup stage. Invariant: may improve or no-op, never lose text —
/// every failure path returns the raw transcript unchanged.
public actor FoundationModelPostProcessor: ContextualTextPostProcessor {
    private let requester: any LanguageModelRequesting
    private let vocabulary: [String]
    private let timeout: Duration
    private var appName: String?

    public init(
        requester: any LanguageModelRequesting,
        vocabulary: [String],
        timeout: Duration = .seconds(3)
    ) {
        self.requester = requester
        self.vocabulary = vocabulary
        self.timeout = timeout
    }

    public func setAppContext(name: String?) {
        appName = name
    }

    public func process(_ text: String) async throws -> String {
        guard !text.isEmpty else { return text }
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
                return Self.containsCommandPhrase(text) ? "" : text
            }
            return cleaned
        } catch {
            NSLog("fabulous: LLM cleanup failed, using raw transcript: \(error)")
            return text
        }
    }

    /// The only command that can legitimately empty an utterance.
    public static func containsCommandPhrase(_ text: String) -> Bool {
        text.lowercased().contains("scratch that")
    }

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter FoundationModelPostProcessorTests`
Expected: 7 tests PASS. `swift build --arch arm64` — zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/PostProcessing Tests/PostProcessingTests
git commit -m "feat: LLM cleanup stage with raw-text fallback"
```

---

### Task 3: Real FoundationModels requester + availability

**Files:**
- Create: `Sources/PostProcessing/FoundationModelRequester.swift`
- Create: `Sources/PostProcessing/PostProcessingAvailability.swift`

**Interfaces:**
- Consumes: `LanguageModelRequesting` (Task 2).
- Produces:
  - `@available(macOS 26.0, *) struct FoundationModelRequester: LanguageModelRequesting`, `init()`, `static func prewarm()`.
  - `enum PostProcessingAvailability: Sendable, Equatable { case available, appleIntelligenceOff, modelNotReady, unsupported }` with `static var current: PostProcessingAvailability` (safe on any macOS) and `var explanation: String?` (nil when available) — settings UI (Task 7) shows this.

No unit tests here — behavior depends on the live system model; conditional real-model tests come in Task 8. This task is done when it compiles warning-free.

- [ ] **Step 1: Implement the requester**

Create `Sources/PostProcessing/FoundationModelRequester.swift`:

```swift
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
```

- [ ] **Step 2: Implement availability**

Create `Sources/PostProcessing/PostProcessingAvailability.swift`:

```swift
import FoundationModels

/// Settings-friendly wrapper over the system model's availability.
/// Safe to query on any macOS version.
public enum PostProcessingAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceOff
    case modelNotReady
    case unsupported

    public static var current: PostProcessingAvailability {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unsupported
        }
    }

    /// Why the toggle is disabled; nil when it isn't.
    public var explanation: String? {
        switch self {
        case .available:
            nil
        case .appleIntelligenceOff:
            "Requires Apple Intelligence, which is turned off in System Settings."
        case .modelNotReady:
            "The Apple Intelligence model is still downloading. Try again later."
        case .unsupported:
            "Not supported on this Mac."
        }
    }
}
```

Note: if the SDK's `UnavailableReason` case names differ (e.g. `deviceNotEligible`), map them inside the existing four public cases — the public enum is the contract, the mapping is not.

- [ ] **Step 3: Build and run full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: builds with zero warnings; all existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/PostProcessing
git commit -m "feat: real FoundationModels requester + availability"
```

---

### Task 4: Keystroke injector newline support

**Files:**
- Create: `Sources/TextInjector/KeystrokeSegmenter.swift`
- Modify: `Sources/TextInjector/TextInjector.swift:111-137` (`attemptKeystrokes`)
- Test: `Tests/TextInjectorTests/KeystrokeSegmenterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum KeystrokeSegment: Equatable, Sendable { case text(String); case newline }`, `enum KeystrokeSegmenter { static func segments(of text: String) -> [KeystrokeSegment] }` (both public).

Why: "new paragraph" produces the first multiline transcripts. `keyboardSetUnicodeString` does not reliably produce Return in target apps — newlines must be posted as real Return key events (`kVK_Return`, keycode 36). axInsert and paste handle `\n` natively; no change there.

- [ ] **Step 1: Write the failing test**

Create `Tests/TextInjectorTests/KeystrokeSegmenterTests.swift`:

```swift
import Testing
@testable import TextInjector

struct KeystrokeSegmenterTests {
    @Test func plainTextIsOneSegment() {
        #expect(KeystrokeSegmenter.segments(of: "hello") == [.text("hello")])
    }

    @Test func newlineSplitsSegments() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\nb")
                == [.text("a"), .newline, .text("b")]
        )
    }

    @Test func paragraphBreakIsTwoNewlines() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\n\nb")
                == [.text("a"), .newline, .newline, .text("b")]
        )
    }

    @Test func crlfIsOneNewline() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\r\nb")
                == [.text("a"), .newline, .text("b")]
        )
    }

    @Test func leadingAndTrailingNewlines() {
        #expect(
            KeystrokeSegmenter.segments(of: "\na\n")
                == [.newline, .text("a"), .newline]
        )
    }

    @Test func emptyTextIsEmpty() {
        #expect(KeystrokeSegmenter.segments(of: "").isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/kal/fabulous && swift test --filter KeystrokeSegmenterTests`
Expected: FAIL — `cannot find 'KeystrokeSegmenter'`.

- [ ] **Step 3: Implement the segmenter**

Create `Sources/TextInjector/KeystrokeSegmenter.swift`:

```swift
public enum KeystrokeSegment: Equatable, Sendable {
    case text(String)
    case newline
}

/// Splits text for the keystroke strategy: `keyboardSetUnicodeString`
/// can't reliably type Return, so newlines become real key events.
public enum KeystrokeSegmenter {
    public static func segments(of text: String) -> [KeystrokeSegment] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [KeystrokeSegment] = []
        var run = ""
        for character in normalized {
            if character == "\n" {
                if !run.isEmpty {
                    result.append(.text(run))
                    run = ""
                }
                result.append(.newline)
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty {
            result.append(.text(run))
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/kal/fabulous && swift test --filter KeystrokeSegmenterTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Use segments in attemptKeystrokes**

In `Sources/TextInjector/TextInjector.swift`, replace the body of `attemptKeystrokes` (keep `postKeystroke` unchanged). The existing UTF-16 chunk loop moves into a helper that handles one text run:

```swift
    private func attemptKeystrokes(_ text: String) async -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for segment in KeystrokeSegmenter.segments(of: text) {
            switch segment {
            case .newline:
                guard postKeystroke(keyCode: CGKeyCode(kVK_Return), flags: []) else {
                    return false
                }
                try? await Task.sleep(for: .milliseconds(5))
            case let .text(run):
                guard await postUnicodeString(run, source: source) else {
                    return false
                }
            }
        }
        return true
    }

    private func postUnicodeString(_ text: String, source: CGEventSource) async -> Bool {
        let units = Array(text.utf16)
        // keyboardSetUnicodeString caps out around 20 UTF-16 units per event.
        let chunkSize = 20
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(
                    stringLength: chunk.count, unicodeString: buffer.baseAddress
                )
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index += chunkSize
            // Some apps drop events posted faster than they can process.
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
```

(`kVK_Return` comes from the already-imported `Carbon.HIToolbox`.)

- [ ] **Step 6: Full build + tests**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test --filter TextInjectorTests`
Expected: zero warnings, all TextInjector tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/TextInjector Tests/TextInjectorTests
git commit -m "feat: keystroke strategy types Return for newlines"
```

---

### Task 5: HistoryStore rawText column

**Files:**
- Modify: `Sources/HistoryStore/HistoryStore.swift` (TranscriptEntry ~line 6-34, migrator ~line 140, `record` ~line 173)
- Test: `Tests/HistoryStoreTests/HistoryStoreTests.swift` (append tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `TranscriptEntry.rawText: String?`; `HistoryStore.record(text:rawText:audioSeconds:modelID:cap:date:)` where `rawText: String? = nil` — AppController passes it in Task 6, History pane reads it in Task 7.

- [ ] **Step 1: Write the failing tests**

Append to the existing suite in `Tests/HistoryStoreTests/HistoryStoreTests.swift` (match the file's existing style for store construction — it uses `HistoryStore.inMemory()`):

```swift
    @Test func recordStoresRawTextWhenProvided() throws {
        let store = try HistoryStore.inMemory()
        try store.record(
            text: "Ship it.", rawText: "um ship it",
            audioSeconds: 1.2, modelID: "test", cap: 10
        )
        let entries = try store.recent()
        #expect(entries.first?.text == "Ship it.")
        #expect(entries.first?.rawText == "um ship it")
    }

    @Test func rawTextDefaultsToNil() throws {
        let store = try HistoryStore.inMemory()
        try store.record(text: "hello", audioSeconds: 1, modelID: "test", cap: 10)
        #expect(try store.recent().first?.rawText == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous && swift test --filter HistoryStoreTests`
Expected: FAIL — `extra argument 'rawText' in call` / `value of type 'TranscriptEntry' has no member 'rawText'`.

- [ ] **Step 3: Implement**

In `Sources/HistoryStore/HistoryStore.swift`:

1. `TranscriptEntry`: add `public var rawText: String?` after `modelID`, add `rawText: String? = nil` as the last init parameter and assign it. Update the doc comment: raw pre-cleanup text is kept only when LLM cleanup changed the transcript.
2. Migrator: append after the `"v3-metrics-streamed"` migration:

```swift
        migrator.registerMigration("v4-transcript-rawtext") { db in
            try db.alter(table: TranscriptEntry.databaseTableName) { t in
                // Pre-LLM-cleanup transcript; NULL when cleanup was off
                // or changed nothing.
                t.add(column: "rawText", .text)
            }
        }
```

3. `record`: add parameter `rawText: String? = nil` (after `text`), pass through to `TranscriptEntry(text: text, createdAt: date, audioSeconds: audioSeconds, modelID: modelID, rawText: rawText)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous && swift test --filter HistoryStoreTests`
Expected: all pass, including pre-existing tests (Codable + GRDB decode `rawText` as nullable automatically).

- [ ] **Step 5: Commit**

```bash
git add Sources/HistoryStore Tests/HistoryStoreTests
git commit -m "feat: history keeps raw transcript when LLM changed it"
```

---

### Task 6: Settings storage + AppController wiring

**Files:**
- Modify: `Sources/FabulousApp/SettingsStore.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (import, stored property ~line 45, init callbacks ~line 114-131, `finishRecording` ~line 494-500, `recordHistory` ~line 644, new `rebuildLLMProcessor`)
- Test: `Tests/PipelineTests/` — add `PostProcessingOrderTests.swift`

FabulousApp is an executable target with no test target; correctness here is compile + the cross-module order test + manual verification in Task 7.

**Interfaces:**
- Consumes: `ContextualTextPostProcessor`, `FoundationModelPostProcessor`, `FoundationModelRequester`, `PostProcessingAvailability` (Tasks 2-3); `HistoryStore.record(text:rawText:...)` (Task 5).
- Produces: `SettingsStore.llmCleanupEnabled: Bool`, `SettingsStore.llmVocabulary: [String]`, `SettingsStore.onLLMCleanupChanged: (() -> Void)?` — settings UI binds these in Task 7.

- [ ] **Step 1: SettingsStore additions**

In `Sources/FabulousApp/SettingsStore.swift`:

Keys (inside `enum Keys`):

```swift
        static let llmCleanupEnabled = "llmCleanupEnabled"
        static let llmVocabulary = "llmVocabulary"
```

Callback (with the other `@ObservationIgnored` callbacks):

```swift
    @ObservationIgnored var onLLMCleanupChanged: (() -> Void)?
```

Properties (after `replacementEntries`):

```swift
    /// LLM transcript cleanup (Apple Foundation Models). Off by default —
    /// it adds latency before injection.
    var llmCleanupEnabled: Bool {
        didSet {
            guard llmCleanupEnabled != oldValue else { return }
            defaults.set(llmCleanupEnabled, forKey: Keys.llmCleanupEnabled)
            onLLMCleanupChanged?()
        }
    }

    /// Names and jargon the cleanup model should prefer when audio is
    /// ambiguous. Feeds only the LLM prompt.
    var llmVocabulary: [String] {
        didSet {
            guard llmVocabulary != oldValue else { return }
            defaults.set(llmVocabulary, forKey: Keys.llmVocabulary)
            onLLMCleanupChanged?()
        }
    }
```

Init (with the other reads; `bool(forKey:)` defaults to false, which is the spec default):

```swift
        llmCleanupEnabled = defaults.bool(forKey: Keys.llmCleanupEnabled)
        llmVocabulary = defaults.stringArray(forKey: Keys.llmVocabulary) ?? []
```

- [ ] **Step 2: AppController wiring**

In `Sources/FabulousApp/AppController.swift`:

1. Add `import PostProcessing` to the imports.
2. Near the existing `postProcessor` property (line ~45), add:

```swift
    /// LLM cleanup stage; nil when disabled or the model is unavailable.
    /// Runs before `postProcessor` so deterministic replacements win.
    private var llmProcessor: (any ContextualTextPostProcessor)?
```

3. In `start()` next to `settings.onReplacementsChanged` (line ~114), add:

```swift
        settings.onLLMCleanupChanged = { [weak self] in self?.rebuildLLMProcessor() }
```

and next to the existing `rebuildPostProcessor()` call (line ~131) add `rebuildLLMProcessor()`.

4. New method next to `rebuildPostProcessor()`:

```swift
    /// (Re)creates the LLM stage. Vocabulary is baked into the instructions,
    /// so a vocabulary edit also lands here via onLLMCleanupChanged.
    private func rebuildLLMProcessor() {
        guard settings.llmCleanupEnabled,
              PostProcessingAvailability.current == .available,
              #available(macOS 26.0, *)
        else {
            llmProcessor = nil
            return
        }
        llmProcessor = FoundationModelPostProcessor(
            requester: FoundationModelRequester(),
            vocabulary: settings.llmVocabulary
        )
        FoundationModelRequester.prewarm()
    }
```

5. In `finishRecording`, replace the post-processing lines (currently):

```swift
            let transcribedAt = clock.now
            let text = try await postProcessor.process(transcript.text)
            let processedAt = clock.now
```

with:

```swift
            let transcribedAt = clock.now
            let rawText = transcript.text
            var cleaned = rawText
            if let llmProcessor {
                await llmProcessor.setAppContext(name: recordingTargetAppName())
                // The LLM stage never throws — it falls back to raw internally.
                cleaned = (try? await llmProcessor.process(rawText)) ?? rawText
            }
            let text = try await postProcessor.process(cleaned)
            let processedAt = clock.now
            let llmChangedText = cleaned != rawText
```

and change the history call a few lines below from
`recordHistory(text: text, audioSeconds: ...)` to:

```swift
            recordHistory(
                text: text,
                rawText: llmChangedText ? rawText : nil,
                audioSeconds: transcript.audioDuration ?? audio.duration
            )
```

(The existing `guard !text.isEmpty` above stays exactly where it is — a
legitimate whole-utterance "scratch that" produces empty text, injects
nothing, and the overlay hides. That is the specced behavior.)

6. Helper near `recordHistory` — the app hint must be the injection
target (the app focused at recording start), not whatever is frontmost
after transcription:

```swift
    /// Name of the app dictation started in — the injection target.
    private func recordingTargetAppName() -> String? {
        recordingTargetPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
    }
```

7. Update `recordHistory` signature:

```swift
    private func recordHistory(text: String, rawText: String?, audioSeconds: TimeInterval) {
        guard settings.historyEnabled, let history else { return }
        do {
            try history.record(
                text: text,
                rawText: rawText,
                audioSeconds: audioSeconds,
                modelID: activeModelID ?? "unknown",
                cap: settings.historyCap
            )
        } catch {
            NSLog("fabulous: failed to record history: \(error)")
        }
    }
```

- [ ] **Step 3: Write the pipeline order test**

Create `Tests/PipelineTests/PostProcessingOrderTests.swift` (mirrors the
controller's LLM-then-replacements chaining as a cross-module contract):

```swift
import FabCore
import Testing

/// Stands in for the LLM stage.
private struct FakeCleanup: TextPostProcessor {
    func process(_ text: String) async throws -> String {
        text.replacingOccurrences(of: "um ", with: "")
    }
}

struct PostProcessingOrderTests {
    @Test func replacementsApplyToLLMOutput() async throws {
        let replacements = ReplacementDictionary(entries: [
            .init(pattern: "anthropic", replacement: "Anthropic")
        ])
        let pipeline = PostProcessingPipeline(stages: [FakeCleanup(), replacements])
        let result = try await pipeline.process("um anthropic ships")
        #expect(result == "Anthropic ships")
    }
}
```

- [ ] **Step 4: Build + full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all tests pass (including the new order test).

- [ ] **Step 5: Commit**

```bash
git add Sources/FabulousApp Tests/PipelineTests
git commit -m "feat: wire LLM cleanup into dictation pipeline"
```

---

### Task 7: Settings UI + history raw display

**Files:**
- Modify: `Sources/FabulousApp/SettingsView.swift` (`GeneralSettingsPane` ~line 92-222, `HistorySettingsPane` ~line 404-460)

**Interfaces:**
- Consumes: `SettingsStore.llmCleanupEnabled`, `SettingsStore.llmVocabulary` (Task 6); `PostProcessingAvailability` (Task 3); `TranscriptEntry.rawText` (Task 5).
- Produces: UI only.

- [ ] **Step 1: Cleanup section in GeneralSettingsPane**

Add `import PostProcessing` to `SettingsView.swift`'s imports.

In `GeneralSettingsPane`, add state + a computed property with the other `@State` vars:

```swift
    @State private var newVocabularyTerm = ""

    private var cleanupAvailability: PostProcessingAvailability {
        PostProcessingAvailability.current
    }
```

Insert this section directly after the `Transcription` section's closing brace (after the `if #available(macOS 26.0, *)` block, before the launch-at-login `Section {`):

```swift
            Section("Clean up with Apple Intelligence") {
                Toggle("Clean up transcripts", isOn: $store.llmCleanupEnabled)
                    .disabled(cleanupAvailability != .available)
                if let explanation = cleanupAvailability.explanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Removes filler words, fixes punctuation, and understands “new paragraph”, “scratch that”, and “quote … unquote”. Runs on this Mac — nothing leaves it. Adds a moment before text appears.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.llmCleanupEnabled {
                    HStack {
                        TextField("Add a name or term…", text: $newVocabularyTerm)
                            .onSubmit(addVocabularyTerm)
                        Button("Add", action: addVocabularyTerm)
                            .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(Array(store.llmVocabulary.enumerated()), id: \.offset) { index, term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                store.llmVocabulary.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("Spellings the cleanup pass should prefer — names, jargon, product terms.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
```

And the helper method next to `beginCapture()`:

```swift
    private func addVocabularyTerm() {
        let term = newVocabularyTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !store.llmVocabulary.contains(term) else { return }
        store.llmVocabulary.append(term)
        newVocabularyTerm = ""
    }
```

- [ ] **Step 2: Raw text in HistorySettingsPane**

In the history row's `VStack` (currently `Text(entry.text)` + date), insert between them:

```swift
                                if let raw = entry.rawText {
                                    Text("Original: \(raw)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
```

- [ ] **Step 3: Build**

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: zero warnings.

- [ ] **Step 4: Manual verification (real bundle — TCC needs it)**

```bash
cd /Users/kal/fabulous && CONFIG=debug scripts/build.sh && open build/fabulous.app
```

Checklist:
1. Settings → General shows "Clean up with Apple Intelligence". Toggle enabled iff Apple Intelligence is on (check the footnote text otherwise).
2. Enable toggle, add a vocabulary term, quit + relaunch — both persist.
3. Dictate "um so I think we should uh ship it" into TextEdit → filler-free text lands; menu latency line shows the extra post ms.
4. Dictate "first line new paragraph second line" → two paragraphs land (tests axInsert/paste `\n`).
5. Dictate "blah blah scratch that" → nothing injected, overlay hides, no error.
6. Settings → History: the cleaned entry shows an "Original: …" line.
7. Toggle cleanup off → dictation injects raw text again, no "Original:" on new entries.

If `build.sh` fails with `errSecInternalComponent`: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db` and retry.

- [ ] **Step 5: Commit**

```bash
git add Sources/FabulousApp
git commit -m "feat: cleanup settings UI + raw text in history"
```

---

### Task 8: Conditional real-model tests

**Files:**
- Create: `Tests/PostProcessingTests/RealFoundationModelTests.swift`

**Interfaces:**
- Consumes: `FoundationModelPostProcessor`, `FoundationModelRequester`, `PostProcessingAvailability` (Tasks 2-3).
- Produces: nothing consumed later.

Pattern matches `FAB_REAL_ASR` (see `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` for the existing gating style — mirror it exactly if it differs from below).

- [ ] **Step 1: Write the tests**

Create `Tests/PostProcessingTests/RealFoundationModelTests.swift`:

```swift
import Foundation
import PostProcessing
import Testing

/// Exercises the real on-device model. Opt-in: FAB_REAL_LLM=1 swift test
/// --filter RealFoundationModelTests. The suite trait also requires the
/// model to be available, so an enabled flag on a machine with Apple
/// Intelligence off skips instead of failing (Swift Testing has no
/// runtime skip-from-inside-a-test; gating must happen in the trait).
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["FAB_REAL_LLM"] == "1"
        && PostProcessingAvailability.current == .available),
    .serialized
)
struct RealFoundationModelTests {
    private func makeProcessor(vocabulary: [String] = []) throws -> FoundationModelPostProcessor {
        // Unreachable when the suite trait passed (availability implies
        // macOS 26), but the compiler still needs the #available gate.
        guard #available(macOS 26.0, *) else { throw UnsupportedOS() }
        return FoundationModelPostProcessor(
            requester: FoundationModelRequester(),
            vocabulary: vocabulary,
            timeout: .seconds(30)
        )
    }

    private struct UnsupportedOS: Error {}

    @Test func removesFillerWords() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("um so I think we should uh ship it")
        #expect(!result.lowercased().contains("um"))
        #expect(!result.lowercased().contains(" uh "))
        #expect(result.lowercased().contains("ship it"))
    }

    @Test func newParagraphBecomesBlankLine() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("first point new paragraph second point")
        #expect(result.contains("\n"))
        #expect(!result.lowercased().contains("new paragraph"))
    }

    @Test func scratchThatDropsPrecedingClause() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process(
            "send it tomorrow scratch that send it on Friday"
        )
        #expect(!result.lowercased().contains("scratch"))
        #expect(result.lowercased().contains("friday"))
        #expect(!result.lowercased().contains("tomorrow"))
    }

    @Test func vocabularyBiasesSpelling() async throws {
        let processor = try makeProcessor(vocabulary: ["WhisperKit"])
        let result = try await processor.process("we integrated whisper kit last week")
        #expect(result.contains("WhisperKit"))
    }

    @Test func commandWordsAsContentSurvive() async throws {
        let processor = try makeProcessor()
        let result = try await processor.process("I applied for a new line of credit")
        #expect(result.lowercased().contains("new line of credit"))
    }
}
```

Note: these assert model behavior, not exact strings — a 3B model has
variance. If a test flakes across runs, loosen the assertion (e.g. accept
either spelling) rather than retry-looping; note flakes in the commit body.

- [ ] **Step 2: Run without the flag (must skip)**

Run: `cd /Users/kal/fabulous && swift test --filter RealFoundationModelTests`
Expected: suite skipped (0 tests run).

- [ ] **Step 3: Run with the flag**

Run: `cd /Users/kal/fabulous && FAB_REAL_LLM=1 swift test --filter RealFoundationModelTests`
Expected: 5 tests PASS (or skip if Apple Intelligence is off on this machine — note which happened).

- [ ] **Step 4: Commit**

```bash
git add Tests/PostProcessingTests
git commit -m "test: conditional real-model cleanup tests"
```

---

### Task 9: Docs

**Files:**
- Modify: `CLAUDE.md` (Layout, Gotchas, State/roadmap)
- Modify: `docs/architecture.md` (post-processing pipeline description)
- Modify: `docs/specs/llm-post-processing.md` (status line)

- [ ] **Step 1: CLAUDE.md**

Layout section — add after the `HistoryStore` bullet:

```markdown
- `PostProcessing` — LLM transcript cleanup: `FoundationModelPostProcessor`
  actor (Apple Foundation Models, macOS 26), `CleanupPromptBuilder` (pure),
  `PostProcessingAvailability`; only target importing FoundationModels.
```

Gotchas — add:

```markdown
- **LLM cleanup can only improve or no-op, never lose text**: every failure
  path in `FoundationModelPostProcessor` (throw, timeout, guardrail refusal,
  empty output) returns the raw transcript. Empty output is accepted only
  when the raw text contains "scratch that" — a whole-utterance scratch
  legitimately cleans to nothing. Fresh `LanguageModelSession` per dictation
  — session reuse accumulates context and leaks text across dictations.
- **Keystroke strategy can't type `\n`** via `keyboardSetUnicodeString`;
  `KeystrokeSegmenter` splits text and posts real Return key events between
  runs. Don't collapse that back into a single unicode-string post.
```

State/roadmap — in the "Done:" run-on, append after the CI + dmg clause:

```markdown
LLM post-processing (docs/specs/llm-post-processing.md): opt-in on-device
cleanup via Apple Foundation Models — fillers, punctuation, spoken commands
(new line/paragraph, scratch that, quote…unquote), vocabulary bias, app-name
hint; raw transcript kept in history (`rawText`) when cleanup changed it.
```

And remove "LLM post-processing (interface exists: `TextPostProcessor`)" from the "Not yet built:" list.

- [ ] **Step 2: architecture.md**

Find the post-processing / TextPostProcessor section in `docs/architecture.md` (grep for `TextPostProcessor`) and update it to describe the two-stage pipeline: LLM cleanup (optional, contextual) → replacement dictionary (deterministic, always wins). Keep the file's existing tone and depth — a paragraph, not an essay.

- [ ] **Step 3: Spec status**

In `docs/specs/llm-post-processing.md` change the status line to:

```markdown
Status: implemented 2026-07-03 (this plan: docs/superpowers/plans/2026-07-03-llm-post-processing.md).
```

(Adjust the date to the actual completion date.)

- [ ] **Step 4: Final full verification**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, full suite green.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: LLM post-processing shipped"
```
