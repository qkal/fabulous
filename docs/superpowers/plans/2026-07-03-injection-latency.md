# Injection Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the 300 ms clipboard-restore wait off the paste critical path and record how each dictation was delivered (`axInsert`/`paste`/`keystrokes`/`safetyNet`) in metrics + menu.

**Architecture:** `TextInjector.attemptPaste` returns as soon as ⌘V posts; restore runs in a stored, cancellable Task. FabCore gains a `DeliveryMethod` enum (metrics vocabulary, decoupled from `InjectionStrategy`); `AppController.deliver` returns it; HistoryStore persists it (migration `v6`) and aggregates per-method share + p50 for a new menu line.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, Swift Testing (`@Test`/`#expect`, NOT XCTest), GRDB.

**Spec:** `docs/specs/injection-latency.md` — read it before starting.

## Global Constraints

- Repo root (this worktree): `/Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13` — prefix every build/test command with `cd` to it; never cd into `.build/checkouts`.
- Build: `swift build --arch arm64` (arm64 only; never add x86_64). Zero warnings in our targets — warnings are failures.
- Tests: `swift test` (Swift Testing, not XCTest).
- Dependency rule: feature modules depend only on FabCore. FabCore imports no AppKit. Only HistoryStore imports GRDB.
- GRDB migration names are append-only and unique; next is `v6-metrics-delivery-method` (`v5-metrics-llm` exists).
- Invariant: transcripts are never silently lost — do not touch `safetyNet` semantics.
- Case names of persisted enums are on-disk schema — `DeliveryMethod` raw values must stay `axInsert`/`paste`/`keystrokes`/`safetyNet`.

---

### Task 1: `DeliveryMethod` enum + `DictationMetrics.deliveryMethod` (FabCore)

**Files:**
- Modify: `Sources/FabCore/DictationMetrics.swift`
- Create: `Tests/FabCoreTests/DeliveryMethodTests.swift`
- Modify: `Tests/TextInjectorTests/StrategySelectionTests.swift` (one alignment test)
- Modify: `Package.swift:72` (TextInjectorTests test-target dependencies)

**Interfaces:**
- Consumes: `InjectionStrategy` (`Sources/TextInjector/InjectionStrategy.swift`) — String-backed, cases `axInsert`/`paste`/`keystrokes`, `CaseIterable`.
- Produces: `public enum DeliveryMethod: String, Sendable, Codable, Equatable, CaseIterable { case axInsert, paste, keystrokes, safetyNet }` in FabCore; `DictationMetrics.deliveryMethod: DeliveryMethod` (init param, default `.safetyNet`); `logLine` gains trailing ` via=<rawValue>`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FabCoreTests/DeliveryMethodTests.swift`:

```swift
import Foundation
import Testing

@testable import FabCore

@Suite struct DeliveryMethodTests {
    /// Raw values are the on-disk schema (dictationMetrics.deliveryMethod).
    @Test func rawValuesArePinned() {
        #expect(DeliveryMethod.axInsert.rawValue == "axInsert")
        #expect(DeliveryMethod.paste.rawValue == "paste")
        #expect(DeliveryMethod.keystrokes.rawValue == "keystrokes")
        #expect(DeliveryMethod.safetyNet.rawValue == "safetyNet")
    }

    private func metrics(deliveryMethod: DeliveryMethod) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 2.0,
            stopAndTrim: .milliseconds(40),
            transcription: .milliseconds(900),
            postProcessing: .milliseconds(5),
            delivery: .milliseconds(60),
            total: .milliseconds(1005),
            deliveryMethod: deliveryMethod
        )
    }

    @Test func logLineNamesTheDeliveryMethod() {
        #expect(metrics(deliveryMethod: .paste).logLine.contains(" via=paste"))
        #expect(metrics(deliveryMethod: .safetyNet).logLine.contains(" via=safetyNet"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift test --filter DeliveryMethodTests`
Expected: COMPILE FAILURE — `cannot find 'DeliveryMethod' in scope`.

- [ ] **Step 3: Implement in FabCore**

In `Sources/FabCore/DictationMetrics.swift`, add above `DictationMetrics` (after the `LLMCleanupOutcome` enum, which ends at line 15):

```swift
/// How one dictation's text reached the target app. Persisted by raw value —
/// case names are part of the on-disk schema. Decoupled from TextInjector's
/// InjectionStrategy on purpose: this is "how the text got delivered", which
/// includes the clipboard safety net that is not an injection strategy. The
/// first three raw values intentionally match InjectionStrategy's.
public enum DeliveryMethod: String, Sendable, Codable, Equatable, CaseIterable {
    case axInsert
    case paste
    case keystrokes
    /// Clipboard fallback, any reason: focus change, secure input,
    /// accessibility revoked, or all strategies failed.
    case safetyNet
}
```

In `DictationMetrics`, after `public var streamed: Bool` (line 37):

```swift
    /// How the text reached the target app. Defaults to the conservative
    /// safety-net label; the production caller always passes the real value.
    public var deliveryMethod: DeliveryMethod
```

Add init parameter after `streamed: Bool = false`:

```swift
        streamed: Bool = false,
        deliveryMethod: DeliveryMethod = .safetyNet
```

and in the init body, after `self.streamed = streamed`:

```swift
        self.deliveryMethod = deliveryMethod
```

In `logLine`, append after the `streamed` segment (line 79):

```swift
            + (streamed ? " streamed" : "")
            + " via=\(deliveryMethod.rawValue)"
```

- [ ] **Step 4: Run FabCore tests**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift test --filter DeliveryMethodTests`
Expected: PASS (2 tests).

Also run: `swift test --filter FabCoreTests`
Expected: PASS — existing `DictationMetricsTests`, `DictationMetricsLLMTests`, `DictationMetricsStreamedTests` construct `DictationMetrics` without the new param (it has a default) and don't assert on the logLine tail, so they must stay green. If a streamed test asserts `logLine.hasSuffix(" streamed")`, change it to `.contains(" streamed")` — the via-segment is now the tail.

Note: `Tests/FabCoreTests/DictationMetricsStreamedTests.swift:28` DOES assert `hasSuffix(" streamed")`. Change that line to:

```swift
        #expect(metrics(streamed: true).logLine.contains(" streamed"))
```

- [ ] **Step 5: Write the alignment test (TextInjectorTests)**

In `Package.swift` line 72, add FabCore to the test target so the import is explicit:

```swift
        .testTarget(name: "TextInjectorTests", dependencies: ["TextInjector", "FabCore"]),
```

Append to `Tests/TextInjectorTests/StrategySelectionTests.swift`:

```swift
// Bottom of file — needs: import FabCore (add to the file's imports)

/// DeliveryMethod (FabCore) mirrors InjectionStrategy's raw values so
/// AppController can map by rawValue. A case rename in either enum fails here.
@Test func deliveryMethodCoversEveryInjectionStrategy() {
    for strategy in InjectionStrategy.allCases {
        #expect(
            DeliveryMethod(rawValue: strategy.rawValue) != nil,
            "InjectionStrategy.\(strategy.rawValue) has no DeliveryMethod twin"
        )
    }
}
```

(Place it inside the existing `@Suite` struct if the file uses one; otherwise top level is fine for Swift Testing.)

- [ ] **Step 6: Run the full suite**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift test`
Expected: PASS. (`SileroVADTests` may auto-skip — that's normal.)

- [ ] **Step 7: Commit**

```bash
git add Sources/FabCore/DictationMetrics.swift Tests/FabCoreTests/DeliveryMethodTests.swift Tests/FabCoreTests/DictationMetricsStreamedTests.swift Tests/TextInjectorTests/StrategySelectionTests.swift Package.swift
git commit -m "feat: DeliveryMethod vocabulary in DictationMetrics"
```

---

### Task 2: Async clipboard restore (TextInjector)

**Files:**
- Modify: `Sources/TextInjector/TextInjector.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change — `inject(_:) async throws -> InjectionStrategy` keeps its signature. Behavior change only: paste returns ~50 ms after entry instead of ~350 ms; clipboard restore happens ≥300 ms later off the caller's path.

No new unit tests: the behavior is real-NSPasteboard + synthesized-⌘V timing, which needs Accessibility grants and global mutable clipboard state — the spec designates this manual-verified during dogfood. Existing suite must stay green.

- [ ] **Step 1: Add the stored restore task and cancel it on entry**

In `Sources/TextInjector/TextInjector.swift`, add a property after `private let selector: StrategySelector` (line 17):

```swift
    /// Pending clipboard restore from the last paste. Cancelled when a new
    /// injection starts, so a rapid follow-up dictation can't have its
    /// freshly-written transcript clobbered by the previous restore.
    private var restoreTask: Task<Void, Never>?
```

In `inject(_:)`, after the empty-text guard (line 26):

```swift
        restoreTask?.cancel()
        restoreTask = nil
```

- [ ] **Step 2: Move the restore off the critical path**

Replace the tail of `attemptPaste` — everything from the `// Wait for the target app…` comment through `return true` (lines 99–106) — with:

```swift
        // The text is delivered once ⌘V posts; only clipboard bookkeeping
        // remains. Restore runs off the critical path: wait for the target
        // app to service the paste, then put the old clipboard back —
        // unless something else wrote to the clipboard in the meantime.
        // (Quitting inside this window skips the restore; the clipboard
        // then holds the transcript, never garbage.)
        if let saved {
            restoreTask = Task {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let pasteboard = NSPasteboard.general
                if pasteboard.changeCount == ourChangeCount {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                }
            }
        }
        return true
```

Notes for the implementer:
- `TextInjector` is `@MainActor`; an unstructured `Task {}` created inside it inherits main-actor isolation, so touching `restoreTask` and `NSPasteboard` inside it is legal under strict concurrency. Do NOT use `Task.detached` (loses isolation → compile errors and unsafe pasteboard access).
- The cancelled-sleep `catch { return }` is what makes `inject()`'s cancel effective: a cancelled restore never touches the pasteboard.
- The pre-⌘V code (save, write, 50 ms settle, post, sync-restore on post failure) is unchanged.

- [ ] **Step 3: Build with zero warnings and run the suite**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift build --arch arm64 && swift test`
Expected: build succeeds with zero warnings in our targets; all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/TextInjector/TextInjector.swift
git commit -m "perf: clipboard restore off the paste critical path

Paste delivery no longer awaits the 300 ms restore window; a stored
task restores the clipboard afterwards and a new injection cancels it."
```

---

### Task 3: Persistence + `deliveryStats` (HistoryStore)

**Files:**
- Modify: `Sources/HistoryStore/HistoryStore.swift`
- Create: `Tests/HistoryStoreTests/DeliveryStatsTests.swift`

**Interfaces:**
- Consumes: `DeliveryMethod` from FabCore (Task 1). `HistoryStore.percentile(_:_:)` (exists, `static`).
- Produces:
  - `MetricsEntry.deliveryMethod: DeliveryMethod?` (init param, default `nil`; `nil` = pre-migration row)
  - Migration `v6-metrics-delivery-method`
  - `public struct DeliveryStats` with nested `MethodStats` and `menuSummary: String`
  - `HistoryStore.deliveryStats(limit: Int = 500) throws -> DeliveryStats?`
  - `HistoryStore.rawDeliveryMethods() throws -> [String?]` (test pin, mirrors `rawLLMOutcomes`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/HistoryStoreTests/DeliveryStatsTests.swift`:

```swift
import FabCore
import Foundation
import Testing

@testable import HistoryStore

@Suite struct DeliveryStatsTests {
    private func entry(
        method: DeliveryMethod?,
        deliveryMs: Double = 60,
        secondsAgo: TimeInterval = 0
    ) -> MetricsEntry {
        MetricsEntry(
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000_000 - secondsAgo),
            engineID: "large-v3_turbo",
            audioSeconds: 2,
            stopTrimMs: 40,
            asrMs: 900,
            postMs: 5,
            deliveryMs: deliveryMs,
            totalMs: 1005,
            deliveryMethod: method
        )
    }

    @Test func rawColumnPinsTheSchema() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(method: .paste, secondsAgo: 0))
        try store.recordMetrics(entry(method: nil, secondsAgo: 10))
        // Newest first: paste row, then the pre-migration-style NULL row.
        #expect(try store.rawDeliveryMethods() == ["paste", nil])
    }

    @Test func statsAggregatePerMethodAndExcludeNullRows() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(method: .axInsert, deliveryMs: 8, secondsAgo: 1))
        try store.recordMetrics(entry(method: .axInsert, deliveryMs: 10, secondsAgo: 2))
        try store.recordMetrics(entry(method: .paste, deliveryMs: 58, secondsAgo: 3))
        try store.recordMetrics(entry(method: .safetyNet, deliveryMs: 1, secondsAgo: 4))
        // Pre-migration row: excluded from counts entirely.
        try store.recordMetrics(entry(method: nil, deliveryMs: 999, secondsAgo: 5))

        let stats = try #require(try store.deliveryStats())
        #expect(stats.sampleCount == 4)
        // Fixed display order: axInsert, paste, keystrokes, safetyNet —
        // keystrokes has no rows and is omitted.
        #expect(stats.methods.map(\.method) == [.axInsert, .paste, .safetyNet])
        #expect(stats.methods[0].count == 2)
        #expect(stats.methods[0].p50DeliveryMs == 8)  // nearest-rank p50 of [8, 10]
        #expect(stats.methods[1].count == 1)
        #expect(stats.methods[1].p50DeliveryMs == 58)
    }

    @Test func statsAreNilWithoutQualifyingRows() throws {
        let store = try HistoryStore.inMemory()
        #expect(try store.deliveryStats() == nil)
        try store.recordMetrics(entry(method: nil))
        #expect(try store.deliveryStats() == nil)
    }

    @Test func menuSummaryFormatsSharesAndP50s() {
        let stats = DeliveryStats(
            sampleCount: 100,
            methods: [
                .init(method: .axInsert, count: 60, p50DeliveryMs: 8),
                .init(method: .paste, count: 29, p50DeliveryMs: 58),
                .init(method: .keystrokes, count: 8, p50DeliveryMs: 210),
                .init(method: .safetyNet, count: 3, p50DeliveryMs: 1),
            ]
        )
        #expect(stats.menuSummary
            == "Inject ax 60% 8 ms · paste 29% 58 ms · keys 8% 210 ms · net 3%")
    }

    @Test func menuSummaryOmitsP50ForSafetyNetOnly() {
        let stats = DeliveryStats(
            sampleCount: 2,
            methods: [.init(method: .safetyNet, count: 2, p50DeliveryMs: 1)]
        )
        #expect(stats.menuSummary == "Inject net 100%")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift test --filter DeliveryStatsTests`
Expected: COMPILE FAILURE — `MetricsEntry` has no `deliveryMethod` parameter, `DeliveryStats` not found.

- [ ] **Step 3: Implement**

In `Sources/HistoryStore/HistoryStore.swift`:

(a) `MetricsEntry` — add after `public var llmOutcome: LLMCleanupOutcome` (line 69):

```swift
    /// How the text reached the target app; stored as the enum's raw-value
    /// text. NULL only on rows recorded before the v6 migration.
    public var deliveryMethod: DeliveryMethod?
```

Add init parameter after `llmOutcome: LLMCleanupOutcome = .off`:

```swift
        llmOutcome: LLMCleanupOutcome = .off,
        deliveryMethod: DeliveryMethod? = nil
```

and `self.deliveryMethod = deliveryMethod` at the end of the init body.

(b) Migration — append after the `v5-metrics-llm` registration (line 221), before `return migrator`:

```swift
        migrator.registerMigration("v6-metrics-delivery-method") { db in
            try db.alter(table: MetricsEntry.databaseTableName) { t in
                // NULL = pre-migration row; every new row writes a value.
                t.add(column: "deliveryMethod", .text)
            }
        }
```

(c) `DeliveryStats` — add after the `CleanupStats` struct (line 151):

```swift
/// Delivery-method share + p50 over recent dictations (all engines).
/// Only rows recorded after the v6 migration qualify, which also keeps
/// pre-async-restore delivery times out of the percentiles.
public struct DeliveryStats: Sendable, Equatable {
    public struct MethodStats: Sendable, Equatable {
        public var method: DeliveryMethod
        public var count: Int
        public var p50DeliveryMs: Double

        public init(method: DeliveryMethod, count: Int, p50DeliveryMs: Double) {
            self.method = method
            self.count = count
            self.p50DeliveryMs = p50DeliveryMs
        }
    }

    public var sampleCount: Int
    /// Fixed display order (axInsert, paste, keystrokes, safetyNet);
    /// methods with no rows are absent.
    public var methods: [MethodStats]

    public init(sampleCount: Int, methods: [MethodStats]) {
        self.sampleCount = sampleCount
        self.methods = methods
    }

    /// e.g. "Inject ax 60% 8 ms · paste 29% 58 ms · keys 8% 210 ms · net 3%"
    /// safetyNet shows share only — its "delivery" is a clipboard write,
    /// not comparable to injection latencies.
    public var menuSummary: String {
        let labels: [DeliveryMethod: String] = [
            .axInsert: "ax", .paste: "paste", .keystrokes: "keys", .safetyNet: "net",
        ]
        let parts = methods.map { m in
            let pct = Int((Double(m.count) / Double(sampleCount) * 100).rounded())
            let head = "\(labels[m.method] ?? m.method.rawValue) \(pct)%"
            return m.method == .safetyNet ? head : "\(head) \(Self.time(m.p50DeliveryMs))"
        }
        return "Inject " + parts.joined(separator: " · ")
    }

    static func time(_ ms: Double) -> String {
        ms < 1000
            ? String(format: "%.0f ms", ms)
            : String(format: "%.1f s", ms / 1000)
    }
}
```

(d) Query + raw pin — add after `rawLLMOutcomes()` (line 341):

```swift
    /// Delivery-method share and p50 over the newest `limit` dictations
    /// recorded since the v6 migration; nil when there are none.
    public func deliveryStats(limit: Int = 500) throws -> DeliveryStats? {
        let rows = try dbQueue.read { db in
            try MetricsEntry
                .filter(Column("deliveryMethod") != nil)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        guard !rows.isEmpty else { return nil }
        let order: [DeliveryMethod] = [.axInsert, .paste, .keystrokes, .safetyNet]
        let methods = order.compactMap { method -> DeliveryStats.MethodStats? in
            let times = rows
                .filter { $0.deliveryMethod == method }
                .map(\.deliveryMs)
                .sorted()
            guard !times.isEmpty else { return nil }
            return DeliveryStats.MethodStats(
                method: method,
                count: times.count,
                p50DeliveryMs: Self.percentile(times, 0.5)
            )
        }
        return DeliveryStats(sampleCount: rows.count, methods: methods)
    }

    /// Raw deliveryMethod column values, newest first — pins the on-disk
    /// representation in tests (including NULL for pre-migration rows).
    public func rawDeliveryMethods() throws -> [String?] {
        try dbQueue.read { db in
            try Optional<String>.fetchAll(
                db,
                sql: "SELECT deliveryMethod FROM dictationMetrics ORDER BY createdAt DESC, id DESC"
            )
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift test --filter DeliveryStatsTests`
Expected: PASS (5 tests).

Also run: `swift test --filter HistoryStoreTests`
Expected: PASS — existing migration/roundtrip tests unaffected (new column is nullable with a `nil` init default).

- [ ] **Step 5: Commit**

```bash
git add Sources/HistoryStore/HistoryStore.swift Tests/HistoryStoreTests/DeliveryStatsTests.swift
git commit -m "feat: persist delivery method + per-method delivery stats"
```

---

### Task 4: Wire delivery method through AppController + menu (FabulousApp)

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift` (deliver ~line 566, finishRecording ~line 541, persistMetrics ~line 634, refreshLatencyStats ~line 662)
- Modify: `Sources/FabulousApp/StatusItemController.swift` (menu item ~lines 12, 52, 70; setter after line 140)
- Modify: `CLAUDE.md` (roadmap note)

**Interfaces:**
- Consumes: `DeliveryMethod` (Task 1), `TextInjector.inject(_:) -> InjectionStrategy` (existing), `HistoryStore.deliveryStats()` / `DeliveryStats.menuSummary` / `MetricsEntry(deliveryMethod:)` (Task 3).
- Produces: `deliver(_:) async -> DeliveryMethod`; `StatusItemController.setDeliveryStats(_ summary: String?)`.

No new unit tests: the app layer has no test target (established codebase pattern); `via=` in the log line plus the menu line are the dogfood verification, per spec.

- [ ] **Step 1: `deliver` returns the method**

In `Sources/FabulousApp/AppController.swift`, change `deliver` (line 566) to:

```swift
    /// Injects the transcript — or, when injection is impossible (focus
    /// moved, secure input, all strategies failed), runs the safety net:
    /// the text goes to the clipboard and the pill says why. A transcript
    /// is never silently lost. Returns how the text was delivered.
    private func deliver(_ text: String) async -> DeliveryMethod {
        if let target = recordingTargetPID,
           let current = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           current != target
        {
            safetyNet(text, notice: "Focus changed — transcript copied to clipboard")
            return .safetyNet
        }
        do {
            let strategy = try await injector.inject(text)
            overlay.hide()
            // Raw values are aligned by test; fallback label can't be hit
            // without that test failing first.
            return DeliveryMethod(rawValue: strategy.rawValue) ?? .safetyNet
        } catch let InjectionError.refused(reason) {
            let notice = switch reason {
            case .secureInputActive:
                "Password field — transcript copied to clipboard"
            case .accessibilityNotGranted:
                "Accessibility revoked — transcript copied to clipboard"
            }
            safetyNet(text, notice: notice)
            return .safetyNet
        } catch {
            safetyNet(text, notice: "Couldn't insert — transcript copied to clipboard")
            return .safetyNet
        }
    }
```

- [ ] **Step 2: Thread it into the metrics row**

In `finishRecording`, change line 541 from `await deliver(text)` to:

```swift
            let deliveryMethod = await deliver(text)
```

and add to the `DictationMetrics(...)` construction (line 545), after `streamed: streamed`:

```swift
                streamed: streamed,
                deliveryMethod: deliveryMethod
```

- [ ] **Step 3: Persist + surface the stats line**

In `persistMetrics` (line 638), add to the `MetricsEntry(...)` construction after `llmOutcome: metrics.llmOutcome`:

```swift
                llmOutcome: metrics.llmOutcome,
                deliveryMethod: metrics.deliveryMethod
```

and after the `setCleanupStats` line inside the same `do` block (line 654):

```swift
            let deliveryStats = try history.deliveryStats()
            statusItem.setDeliveryStats(deliveryStats?.menuSummary)
```

In `refreshLatencyStats` (line 662), after the `setCleanupStats` line (line 667):

```swift
        let deliveryStats: DeliveryStats? = (try? history.deliveryStats()) ?? nil
        statusItem.setDeliveryStats(deliveryStats?.menuSummary)
```

- [ ] **Step 4: Menu item (StatusItemController)**

In `Sources/FabulousApp/StatusItemController.swift`:

After line 12 (`private let cleanupStatsItem = …`):

```swift
    private let deliveryStatsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
```

After line 53 (`cleanupStatsItem.isHidden = true …`):

```swift
        deliveryStatsItem.isEnabled = false
        deliveryStatsItem.isHidden = true // until a post-v6 dictation exists
```

In the menu-items array, after `cleanupStatsItem,` (line 70):

```swift
            deliveryStatsItem,
```

After `setCleanupStats` (line 140):

```swift
    /// Delivery-method share + p50 line under the cleanup line; nil hides
    /// it (no post-migration dictations, or metrics store unavailable).
    func setDeliveryStats(_ summary: String?) {
        deliveryStatsItem.title = summary ?? ""
        deliveryStatsItem.isHidden = summary == nil
    }
```

- [ ] **Step 5: Build, test, and smoke-run**

Run: `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift build --arch arm64 && swift test`
Expected: zero warnings, all PASS.

Then: `CONFIG=debug scripts/build.sh && open build/fabulous.app`, dictate once into any text field, and check:
- text lands ~instantly (no 300 ms tail before the pill hides on paste-path apps, e.g. Terminal)
- Console log line ends with ` via=axInsert` / ` via=paste`
- menu shows the `Inject …` line after the first dictation
- clipboard content from before the dictation is back ≥300 ms afterwards

(If `build.sh` fails with `errSecInternalComponent`, the dev keychain locked: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db`.)

- [ ] **Step 6: Update CLAUDE.md**

In `CLAUDE.md`, in the **State / roadmap** "Done:" list, append after the LLM post-processing entry (ends with "…when cleanup changed it."):

```
injection latency (docs/specs/injection-latency.md): paste clipboard
restore moved off the critical path (~370 ms → ~60 ms delivery),
per-dictation DeliveryMethod (axInsert/paste/keystrokes/safetyNet) in
metrics + menu "Inject" stats line.
```

- [ ] **Step 7: Commit**

```bash
git add Sources/FabulousApp/AppController.swift Sources/FabulousApp/StatusItemController.swift CLAUDE.md
git commit -m "feat: delivery-method telemetry in metrics + menu

deliver() reports how the text landed (strategy or safety net); the row
persists it and the menu shows per-method share + p50 delivery."
```

---

## Verification (after all tasks)

- `cd /Users/kal/fabulous/.claude/worktrees/keen-leavitt-f0ce13 && swift build --arch arm64 && swift test` — zero warnings, all green.
- Manual dogfood checklist (spec "Testing" section): paste lands fast, clipboard restores after ~300 ms, rapid double dictation keeps the second transcript's paste intact, `via=` segment present in logs, menu `Inject` line renders.
- Success criteria (spec): paste-path delivery p50 well under 100 ms in the menu after a few dictations.
