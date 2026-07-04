# Screen Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harvest visible text from the app the user dictates into (Accessibility API, no screenshots) and feed salient terms into LLM cleanup vocabulary and SpeechAnalyzer contextual-string biasing.

**Architecture:** New `ScreenReader` SwiftPM target walks the frontmost window's AX tree at recording start (overlapping speech); pure `SalientTermExtractor` in FabCore distills terms; additive seams (`StreamingSession.updateContext` default no-op, opt-in `ContextBiasing` protocol, `ContextualTextPostProcessor.setScreenTerms`) deliver them without touching Whisper/Parakeet. Spec: `docs/specs/screen-context.md`.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing (NOT XCTest), ApplicationServices (AX), macOS 26 `SpeechAnalyzer.setContext`.

## Global Constraints

- Build: `swift build --arch arm64` (arm64 only, never x86_64). Run from repo root — never cd into `.build/checkouts`.
- Zero warnings in our targets under strict concurrency — warnings are defects.
- Tests: `swift test` (Swift Testing: `@Suite`, `@Test`, `#expect` — NOT XCTest).
- FabCore must not import AppKit. Feature modules depend only on FabCore.
- `AudioBuffer` collides with CoreAudio: in files importing AVFoundation write `FabCore.AudioBuffer` (not needed in the new files below).
- macOS 26-only API stays inside `@available(macOS 26.0, *)` scopes (platform floor is macOS 14).
- Invariant: screen context may only improve a dictation — never delay it beyond stated bounds (100 ms batch-side wait max), never fail it, never persist or log screen text verbatim (counts only).
- Commit after every task; end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: FabCore — `ScreenContext`, `SalientTermExtractor`, `TaskTimeout`

**Files:**
- Create: `Sources/FabCore/ScreenContext.swift`
- Create: `Sources/FabCore/SalientTermExtractor.swift`
- Create: `Sources/FabCore/TaskTimeout.swift`
- Test: `Tests/FabCoreTests/SalientTermExtractorTests.swift`
- Test: `Tests/FabCoreTests/TaskTimeoutTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `public struct ScreenContext: Sendable, Equatable { public let windowTitle: String?; public let terms: [String]; public let capturedAt: Date; public init(windowTitle: String?, terms: [String], capturedAt: Date) }`
  - `public enum SalientTermExtractor { public static let defaultCap = 30; public static func terms(from texts: [String], cap: Int = defaultCap) -> [String] }`
  - `public enum TaskTimeout { public static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? }`

- [ ] **Step 1: Write the failing extractor tests**

`Tests/FabCoreTests/SalientTermExtractorTests.swift`:

```swift
import FabCore
import Testing

@Suite struct SalientTermExtractorTests {
    @Test func identifiersAreSalient() {
        let terms = SalientTermExtractor.terms(from: [
            "run the parakeetBackend with user_id and build.sh today",
        ])
        #expect(terms.contains("parakeetBackend"))
        #expect(terms.contains("user_id"))
        #expect(terms.contains("build.sh"))
        #expect(!terms.contains("run"))
        #expect(!terms.contains("today"))
    }

    @Test func pascalCaseAndAllCapsAreSalient() {
        let terms = SalientTermExtractor.terms(from: ["WhisperKit exports JSON"])
        #expect(terms.contains("WhisperKit"))
        #expect(terms.contains("JSON"))
    }

    @Test func digitBearingTokensAreSalient() {
        let terms = SalientTermExtractor.terms(from: ["release v0.0.3 uses EOU120M"])
        #expect(terms.contains("v0.0.3"))
        #expect(terms.contains("EOU120M"))
    }

    @Test func pureNumbersAreNot() {
        #expect(SalientTermExtractor.terms(from: ["pay 12000 by 2026"]).isEmpty)
    }

    @Test func midSentenceCapitalsAreSalient_sentenceStartsAreNot() {
        let terms = SalientTermExtractor.terms(from: [
            "The report went to Marek. Later we shipped.",
        ])
        #expect(terms.contains("Marek"))
        #expect(!terms.contains("The"))
        #expect(!terms.contains("Later"))
    }

    @Test func newlineStartsASentence() {
        let terms = SalientTermExtractor.terms(from: ["first line\nSecond line"])
        #expect(!terms.contains("Second"))
    }

    @Test func trailingSentenceDotIsStripped_interiorDotIsKept() {
        let terms = SalientTermExtractor.terms(from: ["ask Marek. then run build.sh"])
        #expect(terms.contains("Marek"))
        #expect(terms.contains("build.sh"))
        #expect(!terms.contains("Marek."))
    }

    @Test func dedupeIsCaseInsensitive_firstCasingWins() {
        let terms = SalientTermExtractor.terms(from: [
            "WhisperKit is here", "we love whisperkit",
        ])
        #expect(terms.filter { $0.lowercased() == "whisperkit" } == ["WhisperKit"])
    }

    @Test func frequencyOrdersFirst_thenFirstSeen() {
        let terms = SalientTermExtractor.terms(from: [
            "Alpha1 then Beta2 then Beta2",
        ])
        #expect(terms == ["Beta2", "Alpha1"])
    }

    @Test func capLimitsOutput() {
        let text = (1...50).map { "Term\($0)x" }.joined(separator: " ")
        #expect(SalientTermExtractor.terms(from: [text]).count == 30)
        #expect(SalientTermExtractor.terms(from: [text], cap: 5).count == 5)
    }

    @Test func lengthBoundsRejectJunk() {
        let long = String(repeating: "ab", count: 30) // 60 chars
        let terms = SalientTermExtractor.terms(from: ["ab \(long) CamelCaseFine"])
        #expect(terms == ["CamelCaseFine"])
    }

    @Test func emptyInputIsEmpty() {
        #expect(SalientTermExtractor.terms(from: []).isEmpty)
        #expect(SalientTermExtractor.terms(from: ["", "   "]).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail to compile (type missing)**

Run: `swift test --filter SalientTermExtractorTests 2>&1 | tail -5`
Expected: build error — `SalientTermExtractor` not found.

- [ ] **Step 3: Implement `ScreenContext` and `SalientTermExtractor`**

`Sources/FabCore/ScreenContext.swift`:

```swift
import Foundation

/// What the screen reader saw at recording start: the focused window's
/// title and the dictation-relevant vocabulary extracted from its visible
/// text. Ephemeral — lives for one dictation, never persisted or logged
/// verbatim (privacy invariant; log term counts only). No `appName`: it
/// flows separately via `setAppContext`, and resolving it needs AppKit.
public struct ScreenContext: Sendable, Equatable {
    public let windowTitle: String?
    public let terms: [String]
    public let capturedAt: Date

    public init(windowTitle: String?, terms: [String], capturedAt: Date) {
        self.windowTitle = windowTitle
        self.terms = terms
        self.capturedAt = capturedAt
    }
}
```

`Sources/FabCore/SalientTermExtractor.swift`:

```swift
import Foundation

/// Distills harvested screen text into the terms worth biasing dictation
/// with — identifiers, proper nouns, digit-bearing tokens — instead of a
/// raw dump that would blow the cleanup model's small context. Pure;
/// tests pin the heuristics. Heuristics only in v1 (no dictionary lookup:
/// NSSpellChecker is AppKit and FabCore stays AppKit-free).
public enum SalientTermExtractor {
    public static let defaultCap = 30

    /// Token length bounds: shorter is noise ("ab"), longer is minified
    /// junk or base64.
    private static let lengthRange = 3...40

    public static func terms(from texts: [String], cap: Int = defaultCap) -> [String] {
        var order: [String] = []          // first-seen order of lowercased keys
        var counts: [String: Int] = [:]
        var casing: [String: String] = [:] // first-seen original casing

        for text in texts {
            for (token, startsSentence) in rawTokens(in: text) {
                guard isSalient(token, midSentence: !startsSentence) else { continue }
                let key = token.lowercased()
                if counts[key] == nil {
                    order.append(key)
                    casing[key] = token
                }
                counts[key, default: 0] += 1
            }
        }

        return order.enumerated()
            .sorted { lhs, rhs in
                let (lc, rc) = (counts[lhs.element] ?? 0, counts[rhs.element] ?? 0)
                return lc == rc ? lhs.offset < rhs.offset : lc > rc
            }
            .prefix(cap)
            .compactMap { casing[$0.element] }
    }

    /// Tokens are runs of [letters, digits, "_", "."], so "build.sh" and
    /// "user_id" survive as single tokens. Edge dots are trimmed — a
    /// trailing "." is a sentence terminator, and the NEXT token starts a
    /// sentence; "!", "?", and newlines do the same from between tokens.
    static func rawTokens(in text: String) -> [(token: String, startsSentence: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var nextStartsSentence = true

        func flush() {
            guard !current.isEmpty else { return }
            let hadTrailingDot = current.hasSuffix(".")
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !trimmed.isEmpty {
                result.append((trimmed, nextStartsSentence))
                nextStartsSentence = hadTrailingDot
            }
            current = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "_" || character == "." {
                current.append(character)
            } else {
                flush()
                if character == "!" || character == "?" || character == "\n" {
                    nextStartsSentence = true
                }
            }
        }
        flush()
        return result
    }

    static func isSalient(_ token: String, midSentence: Bool) -> Bool {
        guard lengthRange.contains(token.count) else { return false }
        guard token.contains(where: \.isLetter) else { return false } // no pure numbers

        let hasDigit = token.contains(where: \.isNumber)
        let hasUnderscore = token.contains("_")
        let hasInteriorDot = token.dropFirst().dropLast().contains(".")
        let letters = token.filter(\.isLetter)
        let hasUpper = letters.contains(where: \.isUppercase)
        let hasLower = letters.contains(where: \.isLowercase)
        let upperAfterFirst = token.dropFirst().contains(where: \.isUppercase)

        let isCamelOrPascal = hasLower && upperAfterFirst        // parakeetBackend, WhisperKit
        let isAllCaps = hasUpper && !hasLower && token.count <= 10 // JSON, EOU, TDT
        if hasDigit || hasUnderscore || hasInteriorDot || isCamelOrPascal || isAllCaps {
            return true
        }
        // Plain Capitalized word: a proper noun only when not opening a
        // sentence — "Marek said" vs "The report".
        let isCapitalized = token.first?.isUppercase == true && hasLower && !upperAfterFirst
        return isCapitalized && midSentence
    }
}
```

- [ ] **Step 4: Run extractor tests, verify they pass**

Run: `swift test --filter SalientTermExtractorTests 2>&1 | tail -5`
Expected: all tests pass, zero warnings.

- [ ] **Step 5: Write the failing `TaskTimeout` tests**

`Tests/FabCoreTests/TaskTimeoutTests.swift`:

```swift
import FabCore
import Testing

@Suite struct TaskTimeoutTests {
    @Test func fastTaskReturnsValue() async {
        let task = Task { 42 }
        let value = await TaskTimeout.value(of: task, within: .seconds(1))
        #expect(value == 42)
    }

    @Test func slowTaskTimesOutToNil() async {
        let task = Task<Int, Never> {
            try? await Task.sleep(for: .seconds(5))
            return 42
        }
        let value = await TaskTimeout.value(of: task, within: .milliseconds(20))
        #expect(value == nil)
        task.cancel()
    }
}
```

- [ ] **Step 6: Run tests, verify they fail to compile**

Run: `swift test --filter TaskTimeoutTests 2>&1 | tail -5`
Expected: build error — `TaskTimeout` not found.

- [ ] **Step 7: Implement `TaskTimeout`**

`Sources/FabCore/TaskTimeout.swift`:

```swift
import Foundation

/// Bounded await on a task that must not delay its caller: nil on
/// timeout. The task itself keeps running — cancelling it (or not) is
/// the caller's decision.
public enum TaskTimeout {
    public static func value<T: Sendable>(
        of task: Task<T, Never>,
        within limit: Duration
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
```

- [ ] **Step 8: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: everything passes (no existing behavior touched).

- [ ] **Step 9: Commit**

```bash
git add Sources/FabCore/ScreenContext.swift Sources/FabCore/SalientTermExtractor.swift Sources/FabCore/TaskTimeout.swift Tests/FabCoreTests/SalientTermExtractorTests.swift Tests/FabCoreTests/TaskTimeoutTests.swift
git commit -m "feat: ScreenContext, salient-term extractor, bounded task await (FabCore)"
```

---

### Task 2: `ScreenReader` target — pure harvest walk + capture policy

**Files:**
- Modify: `Package.swift` (add target + test target)
- Create: `Sources/ScreenReader/TextHarvester.swift`
- Create: `Sources/ScreenReader/ScreenContextPolicy.swift`
- Test: `Tests/ScreenReaderTests/TextHarvesterTests.swift`
- Test: `Tests/ScreenReaderTests/ScreenContextPolicyTests.swift`

**Interfaces:**
- Consumes: FabCore (nothing specific yet).
- Produces:
  - `public protocol TextHarvestNode { var subrole: String? { get }; var title: String? { get }; var textValue: String? { get }; var children: [Self] { get } }`
  - `public enum TextHarvester { static let defaults…; public static func harvest<Node: TextHarvestNode>(_ root: Node, maxDepth: Int = 12, charCap: Int = 20_000, nodeCap: Int = 2_000, shouldContinue: () -> Bool = { true }) -> [String] }`
  - `public enum ScreenContextPolicy { public static func shouldCapture(enabled: Bool, cleanupOn: Bool, engineBiases: Bool) -> Bool }`

- [ ] **Step 1: Add the target to `Package.swift`**

In the `targets:` array, after the `TextInjector` target entry, add:

```swift
        // Frontmost-window text harvesting via the Accessibility API —
        // uses the Accessibility grant we already hold (no Screen
        // Recording, no screenshots). Feeds ScreenContext to dictation.
        .target(name: "ScreenReader", dependencies: ["FabCore"]),
```

And with the test targets:

```swift
        .testTarget(name: "ScreenReaderTests", dependencies: ["ScreenReader", "FabCore"]),
```

- [ ] **Step 2: Write the failing tests**

`Tests/ScreenReaderTests/TextHarvesterTests.swift`:

```swift
import ScreenReader
import Testing

/// In-memory tree standing in for AXUIElements.
struct FakeNode: TextHarvestNode {
    var subrole: String?
    var title: String?
    var textValue: String?
    var children: [FakeNode] = []
}

@Suite struct TextHarvesterTests {
    @Test func collectsTitlesAndValuesDepthFirst() {
        let tree = FakeNode(
            subrole: nil, title: "Window", textValue: nil,
            children: [
                FakeNode(subrole: nil, title: nil, textValue: "hello"),
                FakeNode(subrole: nil, title: "Sidebar", textValue: "world"),
            ]
        )
        #expect(TextHarvester.harvest(tree) == ["Window", "hello", "Sidebar", "world"])
    }

    @Test func skipsSecureFieldSubtree() {
        let tree = FakeNode(
            subrole: nil, title: nil, textValue: "safe",
            children: [
                FakeNode(
                    subrole: "AXSecureTextField", title: nil, textValue: "hunter2",
                    children: [FakeNode(subrole: nil, title: nil, textValue: "nested-secret")]
                ),
                FakeNode(subrole: nil, title: nil, textValue: "also safe"),
            ]
        )
        let pieces = TextHarvester.harvest(tree)
        #expect(pieces == ["safe", "also safe"])
    }

    @Test func depthLimitStopsDescent() {
        var leaf = FakeNode(subrole: nil, title: nil, textValue: "deep")
        for _ in 0..<5 {
            leaf = FakeNode(subrole: nil, title: nil, textValue: nil, children: [leaf])
        }
        #expect(TextHarvester.harvest(leaf, maxDepth: 3).isEmpty)
        #expect(TextHarvester.harvest(leaf, maxDepth: 5) == ["deep"])
    }

    @Test func charCapTruncatesAndStops() {
        let tree = FakeNode(
            subrole: nil, title: nil, textValue: String(repeating: "a", count: 30),
            children: [FakeNode(subrole: nil, title: nil, textValue: "never reached")]
        )
        let pieces = TextHarvester.harvest(tree, charCap: 10)
        #expect(pieces == [String(repeating: "a", count: 10)])
    }

    @Test func nodeCapBoundsPathologicalTrees() {
        let wide = FakeNode(
            subrole: nil, title: nil, textValue: nil,
            children: (0..<100).map { FakeNode(subrole: nil, title: nil, textValue: "n\($0)") }
        )
        // Root consumes 1 slot; 10 children visited after it.
        #expect(TextHarvester.harvest(wide, nodeCap: 11).count == 10)
    }

    @Test func shouldContinueFalseStopsImmediately() {
        let tree = FakeNode(subrole: nil, title: "T", textValue: "v")
        #expect(TextHarvester.harvest(tree, shouldContinue: { false }).isEmpty)
    }
}
```

`Tests/ScreenReaderTests/ScreenContextPolicyTests.swift`:

```swift
import ScreenReader
import Testing

@Suite struct ScreenContextPolicyTests {
    @Test func disabledNeverCaptures() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: false, cleanupOn: true, engineBiases: true))
    }

    @Test func capturesWhenAnyConsumerExists() {
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: true, engineBiases: false))
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: true))
    }

    @Test func noConsumerNoCapture() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: false))
    }
}
```

- [ ] **Step 3: Run tests, verify they fail to compile**

Run: `swift test --filter TextHarvesterTests 2>&1 | tail -5`
Expected: build error — module `ScreenReader` has no such types.

- [ ] **Step 4: Implement**

`Sources/ScreenReader/TextHarvester.swift`:

```swift
import Foundation

/// Node abstraction over the AX tree so the walk's bounding logic
/// (depth, chars, nodes, secure-field skip, time-box) unit-tests
/// without live Accessibility.
public protocol TextHarvestNode {
    var subrole: String? { get }
    var title: String? { get }
    var textValue: String? { get }
    var children: [Self] { get }
}

/// Depth-first text collection with hard bounds — a misbehaving or
/// enormous window must cost bounded work, never a hang.
public enum TextHarvester {
    public static let defaultMaxDepth = 12
    public static let defaultCharCap = 20_000
    public static let defaultNodeCap = 2_000
    /// Password fields and anything inside them are never read.
    public static let secureSubrole = "AXSecureTextField"

    public static func harvest<Node: TextHarvestNode>(
        _ root: Node,
        maxDepth: Int = defaultMaxDepth,
        charCap: Int = defaultCharCap,
        nodeCap: Int = defaultNodeCap,
        shouldContinue: () -> Bool = { true }
    ) -> [String] {
        var pieces: [String] = []
        var chars = 0
        var nodes = 0

        func visit(_ node: Node, depth: Int) {
            guard shouldContinue(), depth <= maxDepth, chars < charCap, nodes < nodeCap
            else { return }
            nodes += 1
            guard node.subrole != secureSubrole else { return }
            for text in [node.title, node.textValue] {
                guard let text, !text.isEmpty, chars < charCap else { continue }
                let piece = String(text.prefix(charCap - chars))
                pieces.append(piece)
                chars += piece.count
            }
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return pieces
    }
}
```

`Sources/ScreenReader/ScreenContextPolicy.swift`:

```swift
/// The AX walk runs only when someone will consume the result — reading
/// the user's screen for nothing is both wasted work and bad optics.
public enum ScreenContextPolicy {
    public static func shouldCapture(
        enabled: Bool,
        cleanupOn: Bool,
        engineBiases: Bool
    ) -> Bool {
        enabled && (cleanupOn || engineBiases)
    }
}
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `swift test --filter ScreenReaderTests 2>&1 | tail -5`
Expected: all pass. Also run `swift build --arch arm64 2>&1 | tail -3` — zero warnings.

Note on the nodeCap test expectation: the root consumes one node slot and contributes no text; with `nodeCap: 11`, exactly 10 children yield text. If your visit-order accounting differs, fix the CODE to match the documented contract (cap counts visited nodes), not the test.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ScreenReader Tests/ScreenReaderTests
git commit -m "feat: ScreenReader target — bounded AX-tree text harvest (pure core) + capture policy"
```

---

### Task 3: `ScreenReader` — live AX reader

**Files:**
- Create: `Sources/ScreenReader/ScreenContextReading.swift`
- Create: `Sources/ScreenReader/ScreenContextReader.swift`
- Test: `Tests/ScreenReaderTests/RealAXReaderTests.swift` (conditional, `FAB_REAL_AX=1`)

**Interfaces:**
- Consumes: `TextHarvester.harvest`, `SalientTermExtractor.terms(from:)`, `FabCore.ScreenContext`.
- Produces:
  - `public protocol ScreenContextReading: Sendable { func read(pid: pid_t) async -> ScreenContext }`
  - `public struct ScreenContextReader: ScreenContextReading { public init(); public func read(pid: pid_t) async -> ScreenContext }`

- [ ] **Step 1: Write the protocol**

`Sources/ScreenReader/ScreenContextReading.swift`:

```swift
import FabCore
import Foundation

/// Seam for AppController orchestration and tests: the live reader walks
/// AX; fakes return canned contexts.
public protocol ScreenContextReading: Sendable {
    /// Reads the focused window of `pid`. Never throws — any failure
    /// (no AX tree, timeout, dead pid) returns an empty context and the
    /// dictation proceeds exactly as without the feature.
    func read(pid: pid_t) async -> ScreenContext
}
```

- [ ] **Step 2: Write the live reader**

`Sources/ScreenReader/ScreenContextReader.swift`:

```swift
import ApplicationServices
import FabCore
import Foundation

/// Live AX implementation. The entire walk stays inside `read` on one
/// task — AXUIElement is not Sendable and must never escape. The AX
/// calls are synchronous and may block this cooperative thread for up
/// to the walk time-box (~1 s worst case, bounded by per-element
/// messaging timeouts); that is accepted — the walk overlaps recording,
/// nothing awaits it on the hot path.
public struct ScreenContextReader: ScreenContextReading {
    /// Whole-walk budget. Checked between nodes via `shouldContinue`.
    private static let walkBudget: Duration = .seconds(1)
    /// Per-element AX messaging timeout — a hung app costs ≤100 ms per
    /// attribute fetch instead of the 6 s system default.
    private static let messagingTimeout: Float = 0.1

    public init() {}

    public func read(pid: pid_t) async -> ScreenContext {
        let capturedAt = Date()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        guard let window = Self.focusedWindow(of: app) else {
            return ScreenContext(windowTitle: nil, terms: [], capturedAt: capturedAt)
        }
        let root = LiveAXNode(element: window)
        let deadline = ContinuousClock.now.advanced(by: Self.walkBudget)
        let pieces = TextHarvester.harvest(root) {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
        return ScreenContext(
            windowTitle: root.title,
            terms: SalientTermExtractor.terms(from: pieces),
            capturedAt: capturedAt
        )
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(app, attribute as CFString, &value)
            if err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }
}

/// AXUIElement wrapped as a TextHarvestNode. Deliberately NOT Sendable.
struct LiveAXNode: TextHarvestNode {
    let element: AXUIElement

    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }

    /// Prefer the visible portion of large text areas (a log view can
    /// hold megabytes off-screen); fall back to the full value, which
    /// the harvester caps.
    var textValue: String? { visibleText() ?? string(kAXValueAttribute) }

    var children: [LiveAXNode] {
        guard let value = copy(kAXChildrenAttribute),
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        return ((value as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID()
                ? LiveAXNode(element: item as! AXUIElement)
                : nil
        })
    }

    private func copy(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private func string(_ attribute: String) -> String? {
        copy(attribute) as? String
    }

    private func visibleText() -> String? {
        guard let rangeObject = copy(kAXVisibleCharacterRangeAttribute),
              CFGetTypeID(rangeObject) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((rangeObject as! AXValue), .cfRange, &range),
              range.length > 0,
              let axRange = AXValueCreate(.cfRange, &range)
        else { return nil }
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &out
        )
        return err == .success ? out as? String : nil
    }
}
```

Concurrency notes for the implementer:
- The `kAX…Attribute` string constants are used exactly like `Sources/TextInjector/TextInjector.swift:71` already uses them (`kAXFocusedUIElementAttribute as CFString`) — they are fine under strict concurrency. Only `kAXTrustedCheckOptionPrompt` is banned (see CLAUDE.md).
- If the compiler complains about `AXUIElement` inside the `Sendable` struct: `LiveAXNode` must stay internal to the module and never cross an isolation boundary; `ScreenContextReader` itself holds no element state. If needed, mark `LiveAXNode` as `@unchecked Sendable`-free by keeping it local — do NOT add `@unchecked Sendable`.

- [ ] **Step 3: Build and run existing tests**

Run: `swift build --arch arm64 2>&1 | tail -3 && swift test --filter ScreenReaderTests 2>&1 | tail -3`
Expected: builds with zero warnings; Task 2 tests still pass.

- [ ] **Step 4: Add the conditional real-AX test**

`Tests/ScreenReaderTests/RealAXReaderTests.swift` (mirrors the `FAB_REAL_ASR` gating pattern in `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` — look there for the exact enabled-check idiom):

```swift
import AppKit
import FabCore
import ScreenReader
import Testing

/// Real Accessibility walk against TextEdit. Requires:
/// - FAB_REAL_AX=1 in the environment
/// - Accessibility permission for the test runner process
/// Run: FAB_REAL_AX=1 swift test --filter RealAXReaderTests
@Suite struct RealAXReaderTests {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["FAB_REAL_AX"] == "1"
    }

    @Test(.enabled(if: enabled))
    func readsTermsFromTextEditDocument() async throws {
        let marker = "ZyxwvutMarker QuuxFrobnicate42"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-ax-test-\(UUID().uuidString).txt")
        try marker.data(using: .utf8)!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let textEdit = try await NSWorkspace.shared.open(
            [file],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
        defer { textEdit.terminate() }
        try await Task.sleep(for: .seconds(2)) // let the document window appear

        let context = await ScreenContextReader().read(pid: textEdit.processIdentifier)
        #expect(context.terms.contains("ZyxwvutMarker"))
        #expect(context.terms.contains("QuuxFrobnicate42"))
    }
}
```

- [ ] **Step 5: Verify the gate**

Run: `swift test --filter RealAXReaderTests 2>&1 | tail -3`
Expected: test SKIPPED (gate off).
Optionally (interactive machine with AX permission): `FAB_REAL_AX=1 swift test --filter RealAXReaderTests` — passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScreenReader/ScreenContextReading.swift Sources/ScreenReader/ScreenContextReader.swift Tests/ScreenReaderTests/RealAXReaderTests.swift
git commit -m "feat: live AX screen-context reader with time-boxed walk + conditional real-AX test"
```

---

### Task 4: TranscriptionEngine — biasing seams + SpeechAnalyzer wiring

**Files:**
- Modify: `Sources/TranscriptionEngine/StreamingTranscription.swift` (protocol addition + default)
- Create: `Sources/TranscriptionEngine/ContextBiasing.swift`
- Modify: `Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift`
- Test: `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` (extend conditional suite)

**Interfaces:**
- Consumes: `AnalysisContext` / `SpeechAnalyzer.setContext` (macOS 26 Speech).
- Produces:
  - `StreamingSession` gains `func updateContext(_ terms: [String]) async` — default no-op (FakeSession in PipelineTests and Parakeet's session compile unchanged).
  - `public protocol ContextBiasing: Sendable { func setContextualTerms(_ terms: [String]) async }` — adopted ONLY by `SpeechAnalyzerBackend`.

- [ ] **Step 1: Add the protocol method + default**

In `Sources/TranscriptionEngine/StreamingTranscription.swift`, inside `protocol StreamingSession` after the `cancel()` requirement, add:

```swift
    /// Attaches contextual vocabulary (e.g. on-screen terms) to a session
    /// already in flight. Best-effort and engine-dependent: the default
    /// no-op covers engines without a biasing API. Never throws — a
    /// rejected context is logged and the session continues unbiased.
    func updateContext(_ terms: [String]) async
```

Below the protocol, add:

```swift
extension StreamingSession {
    public func updateContext(_ terms: [String]) async {}
}
```

- [ ] **Step 2: Add `ContextBiasing`**

`Sources/TranscriptionEngine/ContextBiasing.swift`:

```swift
/// Batch-path biasing seam, adopted only by backends whose engine takes
/// contextual vocabulary (today: SpeechAnalyzer). AppController applies
/// it via `as?` before the batch transcribe, so `TranscriptionBackend`
/// and the Whisper/Parakeet backends stay untouched. Terms are
/// per-dictation: stored here, consumed (and cleared) by the next
/// `transcribe` call.
public protocol ContextBiasing: Sendable {
    func setContextualTerms(_ terms: [String]) async
}
```

- [ ] **Step 3: Wire `SpeechAnalyzerBackend`**

In `Sources/TranscriptionEngine/SpeechAnalyzerBackend.swift`:

Add a stored property next to `loadedLocale`:

```swift
    /// On-screen vocabulary for the NEXT batch transcribe; single-shot.
    private var contextualTerms: [String] = []
```

Add the conformance + a context factory (inside the existing `@available(macOS 26.0, *)` actor):

```swift
    public func setContextualTerms(_ terms: [String]) {
        contextualTerms = terms
    }

    static func analysisContext(terms: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings = [.general: terms]
        return context
    }
```

Declare the conformance on the actor: change

```swift
public actor SpeechAnalyzerBackend: StreamingTranscriptionBackend {
```

to

```swift
public actor SpeechAnalyzerBackend: StreamingTranscriptionBackend, ContextBiasing {
```

In `transcribe`, right after `let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)` (the batch one, currently line 68), add:

```swift
        // Plain init(modules:options:) has no analysisContext parameter —
        // setContext after creation is the uniform mechanism (spec).
        let terms = contextualTerms
        contextualTerms = []
        if !terms.isEmpty {
            do {
                try await analyzer.setContext(Self.analysisContext(terms: terms))
            } catch {
                NSLog("fabulous: contextual strings rejected (batch): \(error)")
            }
        }
```

In `SpeechAnalyzerStreamingSession` (same file), add:

```swift
    /// Mid-session biasing: SpeechAnalyzer.setContext works on a running
    /// analyzer, so terms landing after the session started still bias
    /// the rest of the utterance.
    func updateContext(_ terms: [String]) async {
        guard !ended, !terms.isEmpty else { return }
        do {
            try await analyzer.setContext(SpeechAnalyzerBackend.analysisContext(terms: terms))
        } catch {
            NSLog("fabulous: contextual strings rejected (streaming): \(error)")
        }
    }
```

- [ ] **Step 4: Build + full test suite**

Run: `swift build --arch arm64 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: zero warnings; all existing tests pass (default `updateContext` keeps `FakeSession` in `Tests/PipelineTests/StreamingPipelineTests.swift` and Parakeet's session compiling without edits — if either fails to compile, the default extension is wrong; fix the extension, do not edit the fakes).

- [ ] **Step 5: Extend the conditional real-ASR tests**

In `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift`, following the existing `FAB_REAL_ASR` gating and `say`-synthesis helpers already present in that file, add two tests:

```swift
    @Test(.enabled(if: realASREnabled))
    func batchTranscribeAcceptsContextualTerms() async throws {
        let backend = SpeechAnalyzerBackend()
        try await backend.load(model: /* same descriptor the existing tests use */)
        await backend.setContextualTerms(["fabulous", "WhisperKit"])
        let audio = /* reuse the existing say-synthesized fixture helper */
        let transcript = try await backend.transcribe(audio, language: nil, onProgress: nil)
        #expect(!transcript.text.isEmpty)   // biasing must never break decode
    }

    @Test(.enabled(if: realASREnabled))
    func streamingSessionAcceptsMidSessionContext() async throws {
        let backend = SpeechAnalyzerBackend()
        try await backend.load(model: /* same descriptor */)
        let session = try await backend.startStreamingSession()
        await session.updateContext(["fabulous"])   // must not throw or kill session
        /* feed the say-synthesized fixture in chunks as the existing streaming test does */
        let transcript = try await session.finish()
        #expect(!transcript.text.isEmpty)
    }
```

The `/* … */` parts mean: reuse THAT FILE's existing helpers/fixtures verbatim — read the file first; do not invent new synthesis code.

- [ ] **Step 6: Verify gate + run**

Run: `swift test --filter SpeechAnalyzerBackendTests 2>&1 | tail -3`
Expected: skipped without `FAB_REAL_ASR=1`.
Then: `FAB_REAL_ASR=1 swift test --filter SpeechAnalyzerBackendTests 2>&1 | tail -5`
Expected: all pass (needs the OS speech assets installed; first run may download).

- [ ] **Step 7: Commit**

```bash
git add Sources/TranscriptionEngine Tests/TranscriptionEngineTests
git commit -m "feat: contextual-string biasing seams — StreamingSession.updateContext + ContextBiasing (SpeechAnalyzer only)"
```

---

### Task 5: PostProcessing — screen terms in the cleanup vocabulary

**Files:**
- Modify: `Sources/PostProcessing/FoundationModelPostProcessor.swift`
- Test: `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift` (extend)
- Test: `Tests/PostProcessingTests/PreparedSessionTests.swift` (read for the FakeRequester pattern; extend if the prewarm-match test fits better there)

**Interfaces:**
- Consumes: `CleanupPromptBuilder.instructions(vocabulary:appName:)` (unchanged).
- Produces:
  - `ContextualTextPostProcessor` gains `func setScreenTerms(_ terms: [String]) async` — default no-op.
  - `FoundationModelPostProcessor.setScreenTerms(_:)` and `static func mergedVocabulary(user: [String], screen: [String]) -> [String]`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/PostProcessingTests/FoundationModelPostProcessorTests.swift` (reuse that file's existing fake requester — it records the `instructions` it was called with; read the file first and follow its naming):

```swift
    @Test func mergedVocabularyKeepsUserFirstAndDedupes() {
        let merged = FoundationModelPostProcessor.mergedVocabulary(
            user: ["WhisperKit", "Kal"],
            screen: ["whisperkit", "ParakeetTDT", "Kal", "GRDB"]
        )
        #expect(merged == ["WhisperKit", "Kal", "ParakeetTDT", "GRDB"])
    }

    @Test func screenTermsReachInstructions() async {
        let requester = /* this file's recording fake */
        let processor = FoundationModelPostProcessor(requester: requester, vocabulary: ["Kal"])
        await processor.setScreenTerms(["ParakeetTDT"])
        _ = await processor.cleanup("hello parakeet tdt")
        let instructions = /* fake's recorded instructions */
        #expect(instructions.contains("ParakeetTDT"))
        #expect(instructions.contains("Kal"))
    }

    @Test func emptyScreenTermsLeaveInstructionsByteIdentical() async {
        let requester = /* recording fake */
        let processor = FoundationModelPostProcessor(requester: requester, vocabulary: ["Kal"])
        await processor.setScreenTerms([])
        _ = await processor.cleanup("hello")
        #expect(/* recorded instructions */ ==
            CleanupPromptBuilder.instructions(vocabulary: ["Kal"], appName: nil))
    }

    @Test func prepareAfterSetScreenTermsWarmsTheSessionCleanupUses() async {
        // The prewarm contract: prepare() and cleanup() must assemble the
        // SAME instructions when screen terms are set before both —
        // otherwise the warmed session is silently wasted.
        let requester = /* fake that records prepare-instructions AND cleanup-instructions */
        let processor = FoundationModelPostProcessor(requester: requester, vocabulary: [])
        await processor.setScreenTerms(["ZebraTerm"])
        await processor.prepare()
        _ = await processor.cleanup("text")
        #expect(/* prepare instructions */ == /* cleanup instructions */)
    }
```

The `/* … */` parts: read the existing fakes in `FoundationModelPostProcessorTests.swift` / `PreparedSessionTests.swift` and reuse them; extend a fake to record `prepare` instructions if it doesn't already.

- [ ] **Step 2: Run tests, verify failure**

Run: `swift test --filter FoundationModelPostProcessorTests 2>&1 | tail -5`
Expected: build error — no `setScreenTerms` / `mergedVocabulary`.

- [ ] **Step 3: Implement**

In `Sources/PostProcessing/FoundationModelPostProcessor.swift`:

Add to the `ContextualTextPostProcessor` protocol (after `func prepare() async`):

```swift
    /// Per-dictation on-screen vocabulary. The caller resets this every
    /// dictation (stale terms must not leak across dictations). Default
    /// no-op for processors without a vocabulary concept.
    func setScreenTerms(_ terms: [String]) async
```

Extend the existing default-implementation extension:

```swift
extension ContextualTextPostProcessor {
    public func prepare() async {}
    public func setScreenTerms(_ terms: [String]) async {}
}
```

In the `FoundationModelPostProcessor` actor, add next to `appName`:

```swift
    private var screenTerms: [String] = []
```

Add the setter and merge helper:

```swift
    public func setScreenTerms(_ terms: [String]) {
        screenTerms = terms
    }

    /// User vocabulary first and never truncated; screen terms append,
    /// case-insensitive dedupe. Screen terms arrive pre-capped
    /// (SalientTermExtractor.defaultCap) — no second cap here.
    static func mergedVocabulary(user: [String], screen: [String]) -> [String] {
        var seen = Set(user.map { $0.lowercased() })
        var merged = user
        for term in screen where seen.insert(term.lowercased()).inserted {
            merged.append(term)
        }
        return merged
    }

    private func currentInstructions() -> String {
        CleanupPromptBuilder.instructions(
            vocabulary: Self.mergedVocabulary(user: vocabulary, screen: screenTerms),
            appName: appName
        )
    }
```

Replace BOTH existing instruction-assembly sites with `currentInstructions()`:
- in `prepare()`: `let instructions = currentInstructions()` (keep the comment about exact-match warming)
- in `cleanup(_:)`: `let instructions = currentInstructions()`

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test --filter PostProcessingTests 2>&1 | tail -3`
Expected: all pass, including the pre-existing suite (no-terms path byte-identical).

- [ ] **Step 5: Commit**

```bash
git add Sources/PostProcessing Tests/PostProcessingTests
git commit -m "feat: per-dictation screen terms in cleanup vocabulary (setScreenTerms, prewarm-safe merge)"
```

---

### Task 6: SettingsStore toggle + Settings UI

**Files:**
- Modify: `Sources/FabulousApp/SettingsStore.swift`
- Modify: `Sources/FabulousApp/SettingsView.swift`

**Interfaces:**
- Produces: `SettingsStore.useScreenContext: Bool` (default `true`). No change callback — AppController reads it per dictation.

- [ ] **Step 1: Add the setting**

In `Sources/FabulousApp/SettingsStore.swift`:

Add to `Keys`:

```swift
        static let useScreenContext = "useScreenContext"
```

Add the property after `llmVocabulary` (before `let historyCap`):

```swift
    /// Read visible text from the dictation-target app at record start
    /// and use it as vocabulary for ASR biasing + LLM cleanup. On-device
    /// and per-dictation only; checked at each recording, so no change
    /// callback is needed.
    var useScreenContext: Bool {
        didSet { defaults.set(useScreenContext, forKey: Keys.useScreenContext) }
    }
```

Add to `init` (after the `llmVocabulary` line — note the `object(forKey:) as? Bool ?? true` idiom for default-true, same as `historyEnabled`):

```swift
        useScreenContext = defaults.object(forKey: Keys.useScreenContext) as? Bool ?? true
```

- [ ] **Step 2: Add the toggle to the General tab**

In `Sources/FabulousApp/SettingsView.swift`, after the `Section("Clean up with Apple Intelligence") { … }` block (ends near line 222), add:

```swift
            Section("Screen awareness") {
                Toggle("Use on-screen text to improve dictation", isOn: $store.useScreenContext)
                Text("Reads the visible text of the app you dictate into, so names and jargon on screen transcribe correctly. Uses the existing Accessibility permission, stays on this Mac, and is never stored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build + run tests**

Run: `swift build --arch arm64 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: zero warnings, all pass.

- [ ] **Step 4: Visual check (optional but cheap)**

Run: `CONFIG=debug scripts/build.sh && open build/fabulous.app` — open Settings → General, confirm the section renders and the toggle persists across relaunch. (If the keychain is locked and codesign fails with `errSecInternalComponent`: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/FabulousApp/SettingsStore.swift Sources/FabulousApp/SettingsView.swift
git commit -m "feat: screen-context toggle (default on) in Settings → General"
```

---

### Task 7: AppController orchestration + pipeline flow test

**Files:**
- Modify: `Package.swift` (FabulousApp deps + PipelineTests deps)
- Modify: `Sources/FabulousApp/AppController.swift`
- Test: `Tests/PipelineTests/ScreenContextFlowTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6: `ScreenContextReading`/`ScreenContextReader`, `ScreenContextPolicy.shouldCapture`, `TaskTimeout.value(of:within:)`, `ContextBiasing`, `StreamingSession.updateContext`, `ContextualTextPostProcessor.setScreenTerms`.
- Produces: the end-to-end behavior; nothing downstream consumes AppController.

- [ ] **Step 1: Package wiring**

In `Package.swift`:
- Add `"ScreenReader"` to the `FabulousApp` executable target's dependencies.
- Add `"ScreenReader"` and `"PostProcessing"` to the `PipelineTests` test target's dependencies.

- [ ] **Step 2: Write the failing pipeline flow test**

`Tests/PipelineTests/ScreenContextFlowTests.swift`:

```swift
import FabCore
import PostProcessing
import ScreenReader
import Testing

/// Capture → extraction → cleanup-prompt flow with a fake reader — the
/// cross-module contract AppController relies on, minus AppController
/// itself (executable targets can't be imported by tests).
@Suite struct ScreenContextFlowTests {
    struct FakeReader: ScreenContextReading {
        let context: ScreenContext
        func read(pid: pid_t) async -> ScreenContext { context }
    }

    /// Records the instructions each call received.
    actor RecordingRequester: LanguageModelRequesting {
        private(set) var cleanupInstructions: [String] = []
        func cleanup(instructions: String, transcript: String) async throws -> String {
            cleanupInstructions.append(instructions)
            return transcript
        }
        func lastInstructions() -> String? { cleanupInstructions.last }
    }

    @Test func harvestedTermsReachTheCleanupPrompt() async {
        let reader = FakeReader(context: ScreenContext(
            windowTitle: "notes.md",
            terms: SalientTermExtractor.terms(from: ["deploy ParakeetTDT via build.sh"]),
            capturedAt: .distantPast
        ))
        let context = await reader.read(pid: 1)
        #expect(context.terms.contains("ParakeetTDT"))

        let requester = RecordingRequester()
        let processor = FoundationModelPostProcessor(requester: requester, vocabulary: ["Kal"])
        await processor.setScreenTerms(context.terms)
        _ = await processor.cleanup("we deploy parakeet tdt")

        let instructions = await requester.lastInstructions()
        #expect(instructions?.contains("ParakeetTDT") == true)
        #expect(instructions?.contains("Kal") == true)
    }

    @Test func slowReaderTimesOutAndDictationProceedsContextless() async {
        let task = Task<ScreenContext, Never> {
            try? await Task.sleep(for: .seconds(5))
            return ScreenContext(windowTitle: nil, terms: ["late"], capturedAt: .distantPast)
        }
        let context = await TaskTimeout.value(of: task, within: .milliseconds(20))
        #expect(context == nil)   // AppController maps nil to [] and proceeds
        task.cancel()
    }

    @Test func policyGatesTheWalk() {
        #expect(!ScreenContextPolicy.shouldCapture(enabled: false, cleanupOn: true, engineBiases: true))
        #expect(!ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: false, engineBiases: false))
        #expect(ScreenContextPolicy.shouldCapture(enabled: true, cleanupOn: true, engineBiases: false))
    }
}
```

- [ ] **Step 3: Run it, verify failure**

Run: `swift test --filter ScreenContextFlowTests 2>&1 | tail -5`
Expected: fails only if Tasks 1–5 left a contract gap; more likely it PASSES already — that is fine, it pins the contract before AppController starts depending on it. Either way, proceed.

- [ ] **Step 4: Orchestrate in AppController**

In `Sources/FabulousApp/AppController.swift`:

Add `import ScreenReader` to the imports.

Add fields near `recordingTargetPID` (line ~79):

```swift
    /// Reads on-screen text at record start. Live AX in production; the
    /// seam exists because everything downstream of it is tested through
    /// PipelineTests with fakes.
    private let screenReader: any ScreenContextReading = ScreenContextReader()
    private var screenContextTask: Task<ScreenContext, Never>?
```

In `beginRecording()` (line ~410): inside the existing prewarm block, clear stale terms before `prepare()` — the block becomes:

```swift
            if let llmProcessor {
                Task {
                    await llmProcessor.setAppContext(name: recordingTargetAppName())
                    // Last dictation's screen terms must not leak into this
                    // one; the walk below re-populates them if it lands.
                    await llmProcessor.setScreenTerms([])
                    await llmProcessor.prepare()
                }
            }
```

Immediately after that block (still before `hotkey.interceptEscape = true`), add:

```swift
            startScreenContextCapture()
```

Add the two methods (near `startStreamingSessionIfAvailable` for locality):

```swift
    /// Kicks the AX walk so it overlaps the user speaking. On completion
    /// the terms go to both consumers immediately: the live session gets
    /// contextual strings mid-utterance, and the cleanup session re-warms
    /// with the final instructions — still overlapped with speech.
    private func startScreenContextCapture() {
        screenContextTask?.cancel()
        screenContextTask = nil
        guard ScreenContextPolicy.shouldCapture(
            enabled: settings.useScreenContext,
            cleanupOn: settings.llmCleanupEnabled,
            engineBiases: backend is any ContextBiasing
        ), let pid = recordingTargetPID else { return }
        let reader = screenReader
        screenContextTask = Task { [weak self] in
            let context = await reader.read(pid: pid)
            await self?.screenContextCaptured(context)
            return context
        }
    }

    private func screenContextCaptured(_ context: ScreenContext) async {
        guard state == .recording, !context.terms.isEmpty else { return }
        // Privacy: counts only, never the text (spec invariant).
        NSLog("fabulous: screen ctx: \(context.terms.count) terms")
        // Streaming session may not exist yet (its start task races the
        // walk); batch fallback + cleanup below still get the terms.
        await streamingSession?.updateContext(context.terms)
        if let llmProcessor {
            await llmProcessor.setScreenTerms(context.terms)
            await llmProcessor.prepare()
        }
    }

    /// The walk is virtually always done by hotkey release; only
    /// ultra-short dictations race it, and they proceed contextless
    /// rather than wait (100 ms bound, spec).
    private func collectScreenTerms() async -> [String] {
        guard let task = screenContextTask else { return [] }
        screenContextTask = nil
        guard let context = await TaskTimeout.value(of: task, within: .milliseconds(100)) else {
            task.cancel()
            return []
        }
        return context.terms
    }
```

In `cancelRecording()` (line ~471), after `stopLevelUpdates()`, add:

```swift
        screenContextTask?.cancel()
        screenContextTask = nil
```

In `finishRecording()` (line ~499):

After the `let audioIsRaw … recorder.stop(…)` block and its `defer`, before the `guard audio.duration >= minimumUtteranceDuration` check would be too early (the walk should keep running for real utterances only — collect AFTER the short-utterance bail). Concretely: inside the `guard audio.duration >= minimumUtteranceDuration else { … }` body add the cleanup line:

```swift
            screenContextTask?.cancel()
            screenContextTask = nil
```

Then right after `overlay.showTranscribing()`, add:

```swift
        let screenTerms = await collectScreenTerms()
```

Then just before the `StreamingDictation.finalTranscript(` call, add:

```swift
            if !screenTerms.isEmpty, let biasing = batchBackend as? any ContextBiasing {
                await biasing.setContextualTerms(screenTerms)
            }
```

And change the cleanup invocation (currently `await llmProcessor.setAppContext…` + `cleanup`) to set terms explicitly — captured-hook idempotence AND the timeout path both funnel through this single authoritative set:

```swift
            if let llmProcessor {
                await llmProcessor.setAppContext(name: recordingTargetAppName())
                await llmProcessor.setScreenTerms(screenTerms)
                let report = await llmProcessor.cleanup(rawText)
                cleaned = report.text
                llmOutcome = report.outcome
            }
```

- [ ] **Step 5: Build, full suite, zero warnings**

Run: `swift build --arch arm64 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: builds clean, everything passes.

- [ ] **Step 6: Live smoke test**

Run: `CONFIG=debug scripts/build.sh && open build/fabulous.app`
- Enable LLM cleanup (Settings → General) or switch engine to Apple Speech.
- Open a document containing a distinctive term (e.g. "ParakeetTDT"), dictate a sentence speaking that term.
- Check the log: `log stream --predicate 'processImagePath CONTAINS "fabulous"' --style compact` should show `screen ctx: N terms`.
- Toggle "Use on-screen text…" off, dictate again: no `screen ctx` line.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/FabulousApp/AppController.swift Tests/PipelineTests/ScreenContextFlowTests.swift
git commit -m "feat: screen-context orchestration — AX walk at record start feeds ASR biasing + cleanup vocab"
```

---

### Task 8: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/specs/screen-context.md` (status line only)

**Interfaces:** none.

- [ ] **Step 1: CLAUDE.md — Layout section**

Add a module bullet after the `TextInjector` bullet:

```markdown
- `ScreenReader` — screen-context harvest: `ScreenContextReader` walks the
  dictation-target window's AX tree (existing Accessibility grant, no
  Screen Recording), `TextHarvester` bounded walk core (pure, tested),
  `ScreenContextPolicy`. Terms feed SpeechAnalyzer contextual strings +
  LLM cleanup vocabulary.
```

- [ ] **Step 2: CLAUDE.md — Gotchas**

Add one bullet:

```markdown
- **SpeechAnalyzer biasing is `setContext`, not init**: plain
  `SpeechAnalyzer(modules:options:)` takes no `analysisContext:`; call
  `analyzer.setContext(AnalysisContext with .general contextualStrings)`
  after creation — it also works MID-SESSION on a running analyzer
  (that's how streaming gets screen terms without delaying start).
  Screen text itself is memory-only: never persist/log it verbatim
  (log term counts), and `TextHarvester` must keep skipping
  `AXSecureTextField` subtrees.
```

- [ ] **Step 3: CLAUDE.md — State/roadmap**

Append to the roadmap's "Done" run-on (after the Parakeet entry):

```markdown
screen context (docs/specs/screen-context.md): AX-harvested on-screen
vocabulary at record start → SpeechAnalyzer contextual strings + LLM
cleanup vocab; ScreenReader module; default-on toggle in General;
Whisper/Parakeet get the cleanup half only.
```

- [ ] **Step 4: Spec status**

In `docs/specs/screen-context.md` change `**Status:** Approved design, not yet implemented` to `**Status:** Implemented <today's date>`.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/specs/screen-context.md
git commit -m "docs: screen context shipped — layout, gotchas, roadmap"
```

---

## Verification (whole feature)

1. `swift build --arch arm64` — zero warnings.
2. `swift test` — full suite green.
3. `FAB_REAL_AX=1 swift test --filter RealAXReaderTests` — real AX walk (interactive machine with Accessibility granted to the test runner).
4. `FAB_REAL_ASR=1 swift test --filter SpeechAnalyzerBackendTests` — biasing accepted by the real engine.
5. Live smoke test from Task 7 Step 6, including the toggle-off case.
6. Privacy audit: `grep -rn "context.terms\b" Sources/ | grep -i "nslog\|log"` — any hit must log counts, never contents; confirm no screen text reaches `recordHistory` or `DictationMetrics`.
