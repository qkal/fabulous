# Parakeet download fix + UX-invariant test hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix six confirmed defects (download-stuck deadlock, silent transcript loss, two recording races, Parakeet short-utterance failure, offline misclassification) by extracting the deciding logic into pure, unit-tested `FabCore` units, leaving `AppController` as thin effect-glue.

**Architecture:** Pure decision types live in `FabCore` (no AppKit, no side effects — already the home of `DeliveryMethod`, `ModelDescriptor`, `TranscriptionEngineKind`). `AppController` builds an event, calls the pure reducer/decision, and runs the returned effect. This is the only way to get these `@MainActor` invariants under test: `FabulousApp` is an `executableTarget` with **no test target**, so anything left in it is untestable.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM only (no `.xcodeproj`), Swift Testing (`import Testing`, `@Test`, `#expect`, `@Suite` — never XCTest), FluidAudio 0.15.4 (Parakeet), arm64 only.

## Global Constraints

- `swift build --arch arm64` must stay warning-free in our targets. Zero new warnings.
- SwiftPM only — never generate an `.xcodeproj`; never add an x86_64 slice.
- New source files drop into existing targets — **no `Package.swift` changes** (no new targets).
- Tests are Swift Testing, not XCTest.
- Build/test commands run from the repo root (`/Users/kal/fabulous`); never `cd` into `.build/checkouts`.
- `FabCore` imports only `Foundation` — no AppKit, no other product modules. Keep it that way.
- Full build+test gate: `swift build --arch arm64` then `swift test`.
- Commit after each green task. Branch is `parakeet-fix-ux-test-hardening` (already created).

---

## File map

**New (FabCore, pure + tested):**
- `Sources/FabCore/ModelRowState.swift` — model-row status + reducer (D1)
- `Sources/FabCore/TerminalDeliveryDecision.swift` — never-drop-text decision (D2)
- `Sources/FabCore/RecordingGate.swift` — push-to-talk / toggle lifecycle gate (D3, D4)
- `Sources/FabCore/EngineLoadDecision.swift` — engine-change gate + fallback policy (E)
- `Sources/FabCore/StreamStopPolicy.swift` — raw-stop / lazy-trim policy (F)

**New tests:**
- `Tests/FabCoreTests/ModelRowStateTests.swift`
- `Tests/FabCoreTests/TerminalDeliveryDecisionTests.swift`
- `Tests/FabCoreTests/RecordingGateTests.swift`
- `Tests/FabCoreTests/EngineLoadDecisionTests.swift`
- `Tests/FabCoreTests/StreamStopPolicyTests.swift`
- `Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift` (D5)
- `Tests/TranscriptionEngineTests/OfflineClassificationTests.swift` (D6)

**Modified (glue — verified by build + manual smoke, not unit-testable):**
- `Sources/FabulousApp/ModelListModel.swift` — delegate transitions to `ModelRowState`
- `Sources/FabulousApp/AppController.swift` — wire every decision in
- `Sources/TranscriptionEngine/ParakeetBackend.swift` — min-duration guard (D5)
- `Sources/TranscriptionEngine/ModelManager.swift` — broaden `isOffline` (D6)

---

## Task 1: D1 — Model-row state reducer (fixes the reported download-stuck bug)

**Files:**
- Create: `Sources/FabCore/ModelRowState.swift`
- Test: `Tests/FabCoreTests/ModelRowStateTests.swift`
- Modify: `Sources/FabulousApp/ModelListModel.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (`downloadModel` ~289, `noteDownloadProgress` ~306, `refreshModelList` ~315)

**Interfaces:**
- Produces: `enum ModelRowStatus { notInstalled; downloading(Double); installed; active; failed(String) }`;
  `enum ModelRowEvent { downloadStarted; progress(Double); downloadSucceeded(isActive: Bool); downloadFailed(String); reconcile(installed: Bool, isActive: Bool) }`;
  `enum ModelRowState { static func reduce(_ status: ModelRowStatus, _ event: ModelRowEvent) -> ModelRowStatus }`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/ModelRowStateTests.swift`:

```swift
import FabCore
import Testing

@Suite("ModelRowState")
struct ModelRowStateTests {
    @Test func downloadLifecycleReachesInstalled() {
        var s = ModelRowStatus.notInstalled
        s = ModelRowState.reduce(s, .downloadStarted)
        s = ModelRowState.reduce(s, .progress(0.5))
        s = ModelRowState.reduce(s, .progress(1.0))
        s = ModelRowState.reduce(s, .downloadSucceeded(isActive: false))
        #expect(s == .installed)
    }

    @Test func downloadSucceededActiveBecomesActive() {
        #expect(ModelRowState.reduce(.downloading(1.0), .downloadSucceeded(isActive: true)) == .active)
    }

    @Test func reconcileAfterSuccessKeepsInstalled() {
        // The exact deadlock: a finished download must not be re-skipped or reset.
        var s = ModelRowState.reduce(.downloading(1.0), .downloadSucceeded(isActive: false))
        s = ModelRowState.reduce(s, .reconcile(installed: true, isActive: false))
        #expect(s == .installed)
    }

    @Test func reconcileLeavesInFlightDownloadAlone() {
        #expect(ModelRowState.reduce(.downloading(0.4), .reconcile(installed: false, isActive: false)) == .downloading(0.4))
    }

    @Test func reconcileDoesNotClobberFailure() {
        #expect(ModelRowState.reduce(.failed("boom"), .reconcile(installed: false, isActive: false)) == .failed("boom"))
    }

    @Test func reconcilePromotesFreshInstallToActive() {
        #expect(ModelRowState.reduce(.notInstalled, .reconcile(installed: true, isActive: true)) == .active)
    }

    @Test func reconcileMarksMissingNotInstalled() {
        #expect(ModelRowState.reduce(.installed, .reconcile(installed: false, isActive: false)) == .notInstalled)
    }

    @Test func lateProgressAfterSuccessIsIgnored() {
        #expect(ModelRowState.reduce(.installed, .progress(0.9)) == .installed)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelRowState`
Expected: FAIL — `cannot find 'ModelRowState' in scope`.

- [ ] **Step 3: Write the reducer**

Create `Sources/FabCore/ModelRowState.swift`:

```swift
import Foundation

/// Lifecycle status of one model row in the Models tab. Pure value type
/// (moved out of `ModelListModel` so its transitions are unit-testable).
public enum ModelRowStatus: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
    case failed(String)
}

/// Events that drive a model row's status.
public enum ModelRowEvent: Equatable, Sendable {
    case downloadStarted
    case progress(Double)
    /// A download finished successfully; `isActive` when this model is the
    /// one currently loaded in the backend.
    case downloadSucceeded(isActive: Bool)
    case downloadFailed(String)
    /// Disk truth, recomputed by a Models-tab refresh.
    case reconcile(installed: Bool, isActive: Bool)
}

/// Pure reducer for a model row's status.
///
/// Fixes the download-stuck deadlock: previously the only transition to
/// `.installed`/`.active` was a refresh that *skipped* rows still `.downloading`
/// — so a finished download (left at `.downloading(1.0)`) was never promoted and
/// the row hung on a full bar until app restart. Here success is an explicit
/// event, and `reconcile` has defined precedence so it can neither clobber a
/// `.failed` message nor resurrect a finished download.
public enum ModelRowState {
    public static func reduce(_ status: ModelRowStatus, _ event: ModelRowEvent) -> ModelRowStatus {
        switch event {
        case .downloadStarted:
            return .downloading(0)
        case .progress(let fraction):
            // A stray/reordered progress tick can't resurrect a finished/failed row.
            guard case .downloading = status else { return status }
            return .downloading(fraction)
        case .downloadSucceeded(let isActive):
            return isActive ? .active : .installed
        case .downloadFailed(let message):
            return .failed(message)
        case .reconcile(let installed, let isActive):
            switch status {
            case .downloading:
                return status                       // genuinely in-flight; success owns the flip
            case .failed:
                return status                       // preserve the failure message
            default:
                if installed { return isActive ? .active : .installed }
                return .notInstalled
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelRowState`
Expected: PASS (8 tests).

- [ ] **Step 5: Move `Status` into the reducer's type and delegate in `ModelListModel`**

Replace the whole body of `Sources/FabulousApp/ModelListModel.swift` with:

```swift
import FabCore
import Foundation
import Observation

/// UI state for the Models settings tab. Owned and mutated by AppController;
/// the view only reads it and calls actions. Status transitions are delegated
/// to `FabCore.ModelRowState` so they are unit-tested.
@MainActor
@Observable
final class ModelListModel {
    typealias Status = ModelRowStatus

    struct Item: Identifiable {
        let descriptor: ModelDescriptor
        var status: Status
        /// Actual size on disk once installed; nil otherwise.
        var sizeOnDiskMB: Int?

        var id: String { descriptor.id }
    }

    var items: [Item] = ModelCatalog.all.map {
        Item(descriptor: $0, status: .notInstalled, sizeOnDiskMB: nil)
    }

    /// Drives one row's status through the pure reducer.
    func apply(_ event: ModelRowEvent, to modelID: String) {
        guard let index = items.firstIndex(where: { $0.id == modelID }) else { return }
        items[index].status = ModelRowState.reduce(items[index].status, event)
    }

    func updateSize(_ modelID: String, sizeOnDiskMB: Int?) {
        guard let index = items.firstIndex(where: { $0.id == modelID }) else { return }
        items[index].sizeOnDiskMB = sizeOnDiskMB
    }
}
```

(`SettingsView` reads `item.status` and `ModelListModel.Item`/`ModelListModel.Status` — all still resolve via the `typealias`. No `SettingsView` change needed.)

- [ ] **Step 6: Emit `downloadSucceeded` from `downloadModel` and reconcile in `refreshModelList`**

In `Sources/FabulousApp/AppController.swift`, replace `downloadModel` (currently ~289–302):

```swift
    private func downloadModel(_ model: ModelDescriptor, drivesAppState: Bool) async throws {
        modelList.apply(.downloadStarted, to: model.id)
        if drivesAppState { state = .loadingModel(0) }
        do {
            try await modelManager.download(model) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.noteDownloadProgress(model, fraction, drivesAppState: drivesAppState)
                }
            }
        } catch {
            modelList.apply(.downloadFailed(shortErrorText(error)), to: model.id)
            throw error
        }
        // The fix: the success transition is explicit, not a refresh that skips
        // `.downloading` rows. A late progress(1.0) tick is now harmless — the
        // reducer ignores `.progress` on a non-downloading row.
        modelList.apply(.downloadSucceeded(isActive: model.id == activeModelID), to: model.id)
    }
```

Replace the `modelList.update(...)` call inside `noteDownloadProgress` (currently line ~311) with:

```swift
        modelList.apply(.progress(fraction), to: model.id)
```

Replace the whole `refreshModelList` body (currently ~315–332) with:

```swift
    private func refreshModelList() async {
        for descriptor in ModelCatalog.all {
            let installed = await modelManager.isInstalled(descriptor)
            let isActive = descriptor.id == activeModelID
            // reconcile leaves in-flight `.downloading` and `.failed` rows alone.
            modelList.apply(.reconcile(installed: installed, isActive: isActive), to: descriptor.id)
            if installed {
                let bytes = await modelManager.sizeOnDisk(descriptor)
                modelList.updateSize(descriptor.id, sizeOnDiskMB: bytes.map { Int($0 / 1_048_576) })
            } else {
                modelList.updateSize(descriptor.id, sizeOnDiskMB: nil)
            }
        }
    }
```

- [ ] **Step 7: Build and run the full test suite**

Run: `swift build --arch arm64 && swift test`
Expected: build clean (zero warnings), all tests pass including `ModelRowState`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FabCore/ModelRowState.swift Tests/FabCoreTests/ModelRowStateTests.swift \
        Sources/FabulousApp/ModelListModel.swift Sources/FabulousApp/AppController.swift
git commit -m "fix: model download row flips to installed in-session (ModelRowState reducer)"
```

---

## Task 2: D2 — Never drop a transcript (BLOCKER)

**Files:**
- Create: `Sources/FabCore/TerminalDeliveryDecision.swift`
- Test: `Tests/FabCoreTests/TerminalDeliveryDecisionTests.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (`finishRecording` ~659–665, the post-process step)

**Interfaces:**
- Produces: `enum TerminalDelivery: Equatable, Sendable { inject; safetyNet(String); dropSilently }`;
  `enum TerminalDeliveryDecision { static func decide(finalText: String, cleanedText: String) -> TerminalDelivery }`.
- Consumes: nothing.

**Why `cleanedText` is the discriminator:** the LLM stage already returns empty *only* for a
legitimate whole-utterance "scratch that" (else it returns raw — tested in
`FoundationModelPostProcessorTests`). So if the pre-deterministic `cleaned` text was non-empty
but the final `text` is empty, the deterministic post-processor swallowed real speech → must
be safety-netted. If `cleaned` was already empty, the drop is legitimate.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/TerminalDeliveryDecisionTests.swift`:

```swift
import FabCore
import Testing

@Suite("TerminalDeliveryDecision")
struct TerminalDeliveryDecisionTests {
    @Test func nonEmptyFinalTextInjects() {
        #expect(TerminalDeliveryDecision.decide(finalText: "hello", cleanedText: "hello") == .inject)
    }

    @Test func postProcessorSwallowedTextIsSafetyNetted() {
        // cleaned had speech, final is empty → deterministic post-processing ate it.
        #expect(TerminalDeliveryDecision.decide(finalText: "", cleanedText: "hello world")
            == .safetyNet("hello world"))
    }

    @Test func legitimatelyEmptyDropsSilently() {
        // LLM emptied it (scratch-that policy) or nothing was ever said.
        #expect(TerminalDeliveryDecision.decide(finalText: "", cleanedText: "") == .dropSilently)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalDeliveryDecision`
Expected: FAIL — `cannot find 'TerminalDeliveryDecision' in scope`.

- [ ] **Step 3: Write the decision**

Create `Sources/FabCore/TerminalDeliveryDecision.swift`:

```swift
import Foundation

/// What to do with a dictation's final text once processing is done.
public enum TerminalDelivery: Equatable, Sendable {
    /// Non-empty text → hand to the injector.
    case inject
    /// Non-empty text that can't be injected → clipboard + overlay notice.
    case safetyNet(String)
    /// Legitimately empty (true scratch-that, or nothing was said).
    case dropSilently
}

/// Guarantees the "a transcript is never silently lost" invariant at the
/// finish-recording seam: any speech that survived to `cleanedText` but was
/// then emptied by deterministic post-processing is safety-netted, not dropped.
public enum TerminalDeliveryDecision {
    public static func decide(finalText: String, cleanedText: String) -> TerminalDelivery {
        if !finalText.isEmpty { return .inject }
        if !cleanedText.isEmpty { return .safetyNet(cleanedText) }
        return .dropSilently
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalDeliveryDecision`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire it into `finishRecording`**

In `Sources/FabulousApp/AppController.swift`, replace the post-process step and empty-guard
(currently lines ~659–665):

```swift
            let text = try await postProcessor.process(cleaned)
            let processedAt = clock.now
            guard !text.isEmpty else {
                state = .idle
                overlay.hide()
                return
            }
```

with:

```swift
            let text: String
            do {
                text = try await postProcessor.process(cleaned)
            } catch {
                // Deterministic post-processing failed after we had a transcript —
                // never drop it; safety-net the pre-processing text.
                safetyNet(cleaned, notice: "Couldn't process — transcript copied to clipboard")
                state = .idle
                return
            }
            let processedAt = clock.now
            switch TerminalDeliveryDecision.decide(finalText: text, cleanedText: cleaned) {
            case .inject:
                break  // fall through to normal delivery below
            case .safetyNet(let salvage):
                safetyNet(salvage, notice: "Transcript copied to clipboard")
                state = .idle
                return
            case .dropSilently:
                state = .idle
                overlay.hide()
                return
            }
```

(Everything below — `lastTranscript = text`, `recordHistory`, `deliver`, metrics — is unchanged
and runs only on the `.inject` path.)

- [ ] **Step 6: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FabCore/TerminalDeliveryDecision.swift \
        Tests/FabCoreTests/TerminalDeliveryDecisionTests.swift \
        Sources/FabulousApp/AppController.swift
git commit -m "fix: never silently drop a transcript on empty-after-cleanup / post-process throw"
```

---

## Task 3: D3 + D4 — Recording lifecycle gate (fast-tap stuck recorder; toggle double-finish)

**Files:**
- Create: `Sources/FabCore/RecordingGate.swift`
- Test: `Tests/FabCoreTests/RecordingGateTests.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (`hotkeyPressed` ~408, `hotkeyReleased` ~419, `beginRecording` ~424, `cancelRecording` ~546, `finishRecording` ~577; add `recordingGate`, `goLive`, `perform`)

**Interfaces:**
- Produces:
  `struct RecordingGate: Equatable, Sendable` with nested
  `enum Mode { pushToTalk; toggle }`,
  `enum Event { press; release; startSucceeded; startFailed; finished }`,
  `enum Action: Equatable { none; beginStart; goLive; finish; abortToIdle }`,
  `var phase: Phase` (`enum Phase { idle; starting; recording; finishing }`), `init()`,
  and `mutating func handle(_ event: Event, mode: Mode) -> Action`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/RecordingGateTests.swift`:

```swift
import FabCore
import Testing

@Suite("RecordingGate")
struct RecordingGateTests {
    @Test func normalPushToTalkCycle() {
        var g = RecordingGate()
        #expect(g.handle(.press, mode: .pushToTalk) == .beginStart)
        #expect(g.handle(.startSucceeded, mode: .pushToTalk) == .goLive)
        #expect(g.phase == .recording)
        #expect(g.handle(.release, mode: .pushToTalk) == .finish)
        #expect(g.phase == .finishing)
        #expect(g.handle(.finished, mode: .pushToTalk) == .none)
        #expect(g.phase == .idle)
    }

    @Test func fastTapReleaseDuringStartStillFinishes() {
        // D3: release arrives while recorder.start() is still in flight.
        var g = RecordingGate()
        #expect(g.handle(.press, mode: .pushToTalk) == .beginStart)   // .starting
        #expect(g.handle(.release, mode: .pushToTalk) == .none)       // stop deferred
        #expect(g.phase == .starting)
        #expect(g.handle(.startSucceeded, mode: .pushToTalk) == .finish)  // not stuck
        #expect(g.phase == .finishing)
    }

    @Test func startFailureReturnsToIdle() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        #expect(g.handle(.startFailed, mode: .pushToTalk) == .abortToIdle)
        #expect(g.phase == .idle)
    }

    @Test func toggleDoubleFinishOnlyFiresOnce() {
        // D4: two quick toggle presses must not double-finish.
        var g = RecordingGate()
        _ = g.handle(.press, mode: .toggle)              // .starting
        _ = g.handle(.startSucceeded, mode: .toggle)     // .recording
        #expect(g.handle(.press, mode: .toggle) == .finish)   // .finishing
        #expect(g.handle(.press, mode: .toggle) == .none)     // ignored
    }

    @Test func toggleOffBeforeItStartedStillFinishes() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .toggle)              // .starting
        #expect(g.handle(.press, mode: .toggle) == .none)     // toggle-off deferred
        #expect(g.handle(.startSucceeded, mode: .toggle) == .finish)
    }

    @Test func repeatedPushToTalkPressWhileStartingIsIgnored() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        #expect(g.handle(.press, mode: .pushToTalk) == .none)
        #expect(g.phase == .starting)
    }

    @Test func finishedResetsFromAnyPhase() {
        var g = RecordingGate()
        _ = g.handle(.press, mode: .pushToTalk)
        _ = g.handle(.startSucceeded, mode: .pushToTalk)  // .recording
        #expect(g.handle(.finished, mode: .pushToTalk) == .none)  // e.g. Esc-cancel
        #expect(g.phase == .idle)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecordingGate`
Expected: FAIL — `cannot find 'RecordingGate' in scope`.

- [ ] **Step 3: Write the gate**

Create `Sources/FabCore/RecordingGate.swift`:

```swift
import Foundation

/// Pure push-to-talk / toggle lifecycle so the press/release race is testable.
///
/// Fixes two races: a fast PTT tap whose release lands while `recorder.start()`
/// is still awaiting (previously dropped, leaving the recorder running forever),
/// and a double toggle-press that fired `finishRecording` twice.
public struct RecordingGate: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case pushToTalk, toggle }
    public enum Phase: Equatable, Sendable { case idle, starting, recording, finishing }
    public enum Event: Equatable, Sendable { case press, release, startSucceeded, startFailed, finished }
    public enum Action: Equatable, Sendable {
        case none
        case beginStart      // kick recorder.start()
        case goLive          // became recording: overlay, level meter, streaming session
        case finish          // run finishRecording (stop + transcribe)
        case abortToIdle     // start failed → clean up to idle
    }

    public private(set) var phase: Phase = .idle
    private var stopRequested = false

    public init() {}

    public mutating func handle(_ event: Event, mode: Mode) -> Action {
        // `finished` always resets — covers normal finish and Esc-cancel.
        if event == .finished {
            phase = .idle
            stopRequested = false
            return .none
        }
        switch phase {
        case .idle:
            if event == .press {
                phase = .starting
                stopRequested = false
                return .beginStart
            }
            return .none

        case .starting:
            switch event {
            case .release:
                stopRequested = true          // PTT released before recording began
                return .none
            case .press where mode == .toggle:
                stopRequested = true          // toggled off before it started
                return .none
            case .startSucceeded:
                if stopRequested {
                    phase = .finishing        // finishRecording discards if too short
                    return .finish
                }
                phase = .recording
                return .goLive
            case .startFailed:
                phase = .idle
                stopRequested = false
                return .abortToIdle
            default:
                return .none                  // repeated PTT press, stray events
            }

        case .recording:
            switch event {
            case .release where mode == .pushToTalk, .press where mode == .toggle:
                phase = .finishing
                return .finish
            default:
                return .none
            }

        case .finishing:
            return .none                      // second press/release ignored → single finish
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecordingGate`
Expected: PASS (7 tests).

- [ ] **Step 5: Add the gate + dispatcher to `AppController`**

In `Sources/FabulousApp/AppController.swift`, add a stored property near the other UI state
(after `private var screenContextGeneration = 0`, ~line 94):

```swift
    /// Push-to-talk / toggle lifecycle; decides start/goLive/finish from key events.
    private var recordingGate = RecordingGate()
```

Add these helpers (place them just above `hotkeyPressed`, ~line 406):

```swift
    private var gateMode: RecordingGate.Mode {
        settings.hotkeySpec.mode == .toggle ? .toggle : .pushToTalk
    }

    private func perform(_ action: RecordingGate.Action) {
        switch action {
        case .none:
            break
        case .beginStart:
            Task { await beginRecording() }
        case .goLive:
            goLive()
        case .finish:
            Task { await finishRecording() }
        case .abortToIdle:
            state = .idle
            overlay.hide()
        }
    }

    /// The "we are now recording" setup, run when the gate says `.goLive`.
    private func goLive() {
        if let llmProcessor {
            llmPrewarmTask = Task {
                await llmProcessor.setAppContext(name: recordingTargetAppName())
                await llmProcessor.setScreenTerms([])
                await llmProcessor.prepare()
            }
        }
        startScreenContextCapture()
        hotkey.interceptEscape = true
        state = .recording
        overlay.showRecording()
        startLevelUpdates()
        startStreamingSessionIfAvailable()
        if settings.soundCuesEnabled { SoundCues.recordingStarted() }
    }
```

- [ ] **Step 6: Route the hotkey handlers and `beginRecording` through the gate**

Replace `hotkeyPressed` (currently ~408–417) with:

```swift
    private func hotkeyPressed() {
        perform(recordingGate.handle(.press, mode: gateMode))
    }
```

Replace `hotkeyReleased` (currently ~419–422) with:

```swift
    private func hotkeyReleased() {
        guard settings.hotkeySpec.mode == .pushToTalk else { return }
        perform(recordingGate.handle(.release, mode: .pushToTalk))
    }
```

Replace `beginRecording` (currently ~424–454) with:

```swift
    private func beginRecording() async {
        guard Permissions.microphoneGranted else {
            perform(recordingGate.handle(.startFailed, mode: gateMode))
            showOnboarding()
            return
        }
        do {
            try await recorder.start(deviceUID: settings.inputDeviceUID)
            recordingTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // The gate decides whether we go live or (if a release/toggle-off
            // arrived during start) finish immediately — closing the fast-tap race.
            perform(recordingGate.handle(.startSucceeded, mode: gateMode))
        } catch {
            perform(recordingGate.handle(.startFailed, mode: gateMode))
            await flashFailure("Couldn't start recording: \(error)")
        }
    }
```

- [ ] **Step 7: Reset the gate when recording ends or is cancelled**

At the very top of `finishRecording` (currently line ~577, as the first line of the function
body), add:

```swift
        defer { _ = recordingGate.handle(.finished, mode: gateMode) }
```

At the end of `cancelRecording` (currently after `if settings.soundCuesEnabled { SoundCues.recordingCancelled() }`, ~line 558), add:

```swift
        _ = recordingGate.handle(.finished, mode: gateMode)
```

- [ ] **Step 8: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 9: Manual smoke (record the result in the commit body)**

Run: `CONFIG=debug scripts/build.sh && open build/fabulous.app`
Check: (a) fast PTT tap → no stuck recording pill; (b) toggle on/off/on quickly → single dictation, no double-fire; (c) normal PTT and toggle dictation still work.

- [ ] **Step 10: Commit**

```bash
git add Sources/FabCore/RecordingGate.swift Tests/FabCoreTests/RecordingGateTests.swift \
        Sources/FabulousApp/AppController.swift
git commit -m "fix: recording lifecycle gate closes fast-tap stuck recorder + toggle double-finish"
```

---

## Task 4: E1 — Engine-change gate + fallback policy

**Files:**
- Create: `Sources/FabCore/EngineLoadDecision.swift`
- Test: `Tests/FabCoreTests/EngineLoadDecisionTests.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (`onEngineChanged` ~140–143)

**Interfaces:**
- Produces:
  `enum EngineLoadDecision { static func shouldApply(isIdle: Bool, isFailed: Bool) -> Bool; static func fallback(after engine: TranscriptionEngineKind) -> (revertTo: TranscriptionEngineKind, reloadWhisper: Bool) }`.
- Consumes: `FabCore.TranscriptionEngineKind`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/EngineLoadDecisionTests.swift`:

```swift
import FabCore
import Testing

@Suite("EngineLoadDecision")
struct EngineLoadDecisionTests {
    @Test func appliesOnlyWhenIdleOrFailed() {
        #expect(EngineLoadDecision.shouldApply(isIdle: true, isFailed: false))
        #expect(EngineLoadDecision.shouldApply(isIdle: false, isFailed: true))
        #expect(!EngineLoadDecision.shouldApply(isIdle: false, isFailed: false))
    }

    @Test func nonWhisperEngineRevertsToWhisperAndReloads() {
        let r = EngineLoadDecision.fallback(after: .parakeet)
        #expect(r.revertTo == .whisper)
        #expect(r.reloadWhisper)
        let r2 = EngineLoadDecision.fallback(after: .appleSpeech)
        #expect(r2.revertTo == .whisper)
        #expect(r2.reloadWhisper)
    }

    @Test func whisperFailureDoesNotReloadItself() {
        let r = EngineLoadDecision.fallback(after: .whisper)
        #expect(r.revertTo == .whisper)
        #expect(!r.reloadWhisper)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineLoadDecision`
Expected: FAIL — `cannot find 'EngineLoadDecision' in scope`.

- [ ] **Step 3: Write the decision**

Create `Sources/FabCore/EngineLoadDecision.swift`:

```swift
import Foundation

/// Policy for applying and recovering from transcription-engine changes.
public enum EngineLoadDecision {
    /// An engine-preference change takes effect only between utterances; a
    /// mid-recording/loading swap would corrupt the dictation state machine.
    public static func shouldApply(isIdle: Bool, isFailed: Bool) -> Bool {
        isIdle || isFailed
    }

    /// When an engine fails to load, dictation must keep working: revert to
    /// Whisper. Reverting the *preference* alone no-ops (it fires while state
    /// isn't idle/failed), so a non-Whisper failure must also reload Whisper.
    public static func fallback(after engine: TranscriptionEngineKind)
        -> (revertTo: TranscriptionEngineKind, reloadWhisper: Bool) {
        engine == .whisper ? (.whisper, false) : (.whisper, true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EngineLoadDecision`
Expected: PASS (3 tests).

- [ ] **Step 5: Use the gate in `onEngineChanged`**

In `Sources/FabulousApp/AppController.swift`, replace the `onEngineChanged` closure body
(currently ~140–143):

```swift
        settings.onEngineChanged = { [weak self] in
            guard let self, state == .idle || isFailed(state) else { return }
            Task { await self.ensureSelectedModelLoaded() }
        }
```

with:

```swift
        settings.onEngineChanged = { [weak self] in
            guard let self,
                  EngineLoadDecision.shouldApply(isIdle: state == .idle, isFailed: isFailed(state))
            else { return }
            Task { await self.ensureSelectedModelLoaded() }
        }
```

(The `loadAppleSpeech`/`loadParakeet` revert sites already implement `fallback`'s policy —
revert to `.whisper` + explicit `loadWhisper()`. Leave them; the decision now documents and
tests that policy. No behavior change there.)

- [ ] **Step 6: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FabCore/EngineLoadDecision.swift Tests/FabCoreTests/EngineLoadDecisionTests.swift \
        Sources/FabulousApp/AppController.swift
git commit -m "test: extract engine-change gate + fallback policy into FabCore"
```

---

## Task 5: F — Stream-stop / lazy-trim policy

**Files:**
- Create: `Sources/FabCore/StreamStopPolicy.swift`
- Test: `Tests/FabCoreTests/StreamStopPolicyTests.swift`
- Modify: `Sources/FabulousApp/AppController.swift` (`finishRecording` ~598–599 and the fallback closure ~627)

**Interfaces:**
- Produces: `enum StreamStopPolicy { static func trimAtStop(hasSession: Bool) -> Bool; static func needsLazyTrim(hasSession: Bool) -> Bool }`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/FabCoreTests/StreamStopPolicyTests.swift`:

```swift
import FabCore
import Testing

@Suite("StreamStopPolicy")
struct StreamStopPolicyTests {
    @Test func noSessionTrimsAtStopNoLazyTrim() {
        #expect(StreamStopPolicy.trimAtStop(hasSession: false))
        #expect(!StreamStopPolicy.needsLazyTrim(hasSession: false))
    }

    @Test func sessionStopsRawAndTrimsLazily() {
        #expect(!StreamStopPolicy.trimAtStop(hasSession: true))
        #expect(StreamStopPolicy.needsLazyTrim(hasSession: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StreamStopPolicy`
Expected: FAIL — `cannot find 'StreamStopPolicy' in scope`.

- [ ] **Step 3: Write the policy**

Create `Sources/FabCore/StreamStopPolicy.swift`:

```swift
import Foundation

/// When to trim silence relative to stopping the recorder.
///
/// With a live streaming session we stop *raw* (a trim pass at release would
/// re-charge exactly the latency streaming removes) and trim lazily only if we
/// fall back to batch. Without a session the recorder already VAD-trims at stop.
public enum StreamStopPolicy {
    public static func trimAtStop(hasSession: Bool) -> Bool { !hasSession }
    public static func needsLazyTrim(hasSession: Bool) -> Bool { hasSession }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StreamStopPolicy`
Expected: PASS (2 tests).

- [ ] **Step 5: Use the policy in `finishRecording`**

In `Sources/FabulousApp/AppController.swift`, replace the two lines (currently ~598–599):

```swift
        let audioIsRaw = session != nil
        var audio = await recorder.stop(trimming: session == nil)
```

with:

```swift
        let audioIsRaw = StreamStopPolicy.needsLazyTrim(hasSession: session != nil)
        var audio = await recorder.stop(trimming: StreamStopPolicy.trimAtStop(hasSession: session != nil))
```

(The `if audioIsRaw` branch in the fallback closure at ~627 is unchanged — it already keys off
`audioIsRaw`, which now comes from the policy.)

- [ ] **Step 6: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FabCore/StreamStopPolicy.swift Tests/FabCoreTests/StreamStopPolicyTests.swift \
        Sources/FabulousApp/AppController.swift
git commit -m "test: extract stream-stop / lazy-trim policy into FabCore"
```

---

## Task 6: D5 — Parakeet short-utterance guard

**Files:**
- Modify: `Sources/TranscriptionEngine/ParakeetBackend.swift` (`transcribe` ~99–139)
- Test: `Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift`

**Interfaces:**
- Produces: `ParakeetBackend.isBelowBatchMinimum(_ audio: FabCore.AudioBuffer) -> Bool` (static, internal — visible to tests via `@testable import`).
- Consumes: `FabCore.AudioBuffer`.

**Background:** `finishRecording` guards raw audio ≥ 0.25 s, but the batch fallback trims silence
first (`recorder.trimSilence`), which can shrink the buffer below FluidAudio's decoder minimum →
`ASRError.invalidAudioData` thrown from `manager.transcribe`. Guard it: below the threshold,
return an empty `Transcript` (flows to `TerminalDeliveryDecision.dropSilently`) instead of throwing.

- [ ] **Step 1: Write the failing test**

Create `Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift`:

```swift
import FabCore
import Testing
@testable import TranscriptionEngine

@Suite("Parakeet min duration")
struct ParakeetMinDurationTests {
    @Test func subThresholdBufferIsBelowMinimum() {
        // 0.05 s at 16 kHz = 800 samples — below the batch decoder floor.
        let short = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 800), sampleRate: 16_000)
        #expect(ParakeetBackend.isBelowBatchMinimum(short))
    }

    @Test func aboveThresholdBufferIsAllowed() {
        // 0.5 s at 16 kHz = 8000 samples — comfortably decodable.
        let ok = FabCore.AudioBuffer(samples: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
        #expect(!ParakeetBackend.isBelowBatchMinimum(ok))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Parakeet min duration"`
Expected: FAIL — `type 'ParakeetBackend' has no member 'isBelowBatchMinimum'`.

- [ ] **Step 3: Add the guard and helper**

In `Sources/TranscriptionEngine/ParakeetBackend.swift`, add a static helper (inside the actor,
near the top):

```swift
    /// FluidAudio's batch decoder throws `invalidAudioData` on very short
    /// clips. The streaming→batch fallback can hand it a silence-trimmed buffer
    /// well under this; treat those as an empty utterance rather than a throw.
    ///
    /// NOTE (empirical): 0.16 s is a conservative default. Verify with a repro —
    /// synthesize decreasing-length `say` clips, find the length at which
    /// `manager.transcribe` throws `invalidAudioData`, and set this just above it.
    static let batchMinimumDuration: TimeInterval = 0.16

    static func isBelowBatchMinimum(_ audio: FabCore.AudioBuffer) -> Bool {
        audio.duration < batchMinimumDuration
    }
```

In `transcribe`, after the existing `guard !audio.isEmpty` block (currently ~108–110), add:

```swift
        guard !Self.isBelowBatchMinimum(audio) else {
            return Transcript(text: "", audioDuration: audio.duration)
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "Parakeet min duration"`
Expected: PASS (2 tests). Confirm the existing `transcribeWithoutLoadThrowsModelNotLoaded` test
still passes (the `guard let manager` still precedes this guard, so an unloaded backend with a
2-sample buffer still throws `modelNotLoaded`).

- [ ] **Step 5: Pin the threshold with a real repro (if models installed)**

If the Parakeet models are installed locally, verify the default:
Run: `FAB_REAL_ASR=1 swift test --filter ParakeetBackendTests`
If any real-engine short-clip decode still throws `invalidAudioData`, raise `batchMinimumDuration`
until it returns empty, and update the constant + comment. If models aren't installed, leave the
0.16 s default and note it in the commit body.

- [ ] **Step 6: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetBackend.swift \
        Tests/TranscriptionEngineTests/ParakeetMinDurationTests.swift
git commit -m "fix: Parakeet returns empty (not throws) on sub-minimum audio buffers"
```

---

## Task 7: D6 — Broaden offline classification

**Files:**
- Modify: `Sources/TranscriptionEngine/ModelManager.swift` (`isOffline` ~154–163)
- Test: `Tests/TranscriptionEngineTests/OfflineClassificationTests.swift`

**Interfaces:**
- Consumes/Produces: `ModelManager.isOffline(_ error: Error) -> Bool` (already exists, `static`,
  internal — visible to tests via `@testable import`). Behavior widened to recognize non-`URLError`
  network failures that carry `NSURLErrorDomain` (FluidAudio/HuggingFace surface these).

- [ ] **Step 1: Write the failing test**

Create `Tests/TranscriptionEngineTests/OfflineClassificationTests.swift`:

```swift
import Foundation
import Testing
@testable import TranscriptionEngine

@Suite("Offline classification")
struct OfflineClassificationTests {
    @Test func urlErrorIsOffline() {
        #expect(ModelManager.isOffline(URLError(.notConnectedToInternet)))
    }

    @Test func nsurlDomainErrorIsOffline() {
        // FluidAudio/HuggingFace wrap transport failures as plain NSError in NSURLErrorDomain.
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(ModelManager.isOffline(e))
    }

    @Test func unrelatedErrorIsNotOffline() {
        let e = NSError(domain: "SomeOtherDomain", code: 42)
        #expect(!ModelManager.isOffline(e))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "Offline classification"`
Expected: FAIL — `nsurlDomainErrorIsOffline` fails (current `isOffline` only matches `URLError`).

- [ ] **Step 3: Widen `isOffline`**

In `Sources/TranscriptionEngine/ModelManager.swift`, replace `isOffline` (currently ~154–163):

```swift
    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .timedOut:
            return true
        default:
            return false
        }
    }
```

with:

```swift
    static func isOffline(_ error: Error) -> Bool {
        let offlineCodes: Set<Int> = [
            URLError.notConnectedToInternet.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.timedOut.rawValue,
        ]
        if let urlError = error as? URLError {
            return offlineCodes.contains(urlError.code.rawValue)
        }
        // FluidAudio/HuggingFace surface transport failures as plain NSError in
        // NSURLErrorDomain rather than a bridged URLError.
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && offlineCodes.contains(nsError.code)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "Offline classification"`
Expected: PASS (3 tests).

- [ ] **Step 5: Build and test**

Run: `swift build --arch arm64 && swift test`
Expected: clean build, all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranscriptionEngine/ModelManager.swift \
        Tests/TranscriptionEngineTests/OfflineClassificationTests.swift
git commit -m "fix: classify NSURLErrorDomain download failures as offline (friendly fallback)"
```

---

## Task 8: Full-suite verification + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Clean build, zero warnings**

Run: `swift build --arch arm64 2>&1 | grep -i warning || echo "no warnings"`
Expected: `no warnings`.

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: all suites green, including the six new ones.

- [ ] **Step 3: Real-engine Parakeet check (if models installed)**

Run: `FAB_REAL_ASR=1 swift test --filter ParakeetBackendTests`
Expected: PASS or auto-skip (no throw on short clips).

- [ ] **Step 4: Manual smoke on the app bundle**

Run: `CONFIG=debug scripts/build.sh && open build/fabulous.app`
Check, and note results in the final commit body:
- Models tab: download a model → row flips to **installed** in-session (no restart). (D1)
- Dictate, then move focus mid-dictation → transcript lands on clipboard with a notice, never vanishes. (D2)
- Fast PTT tap → no stuck recording pill. (D3)
- Toggle on/off/on quickly → single dictation. (D4)
- Switch engine to Parakeet, dictate a very short blip → no crash, graceful empty. (D5)

- [ ] **Step 5: Final verification commit (if smoke notes are worth recording)**

```bash
git commit --allow-empty -m "chore: manual smoke pass for parakeet-fix + UX hardening

D1 row flips in-session; D2 focus-change safety net; D3/D4 recording races clean;
D5 short parakeet blip graceful."
```

---

## Self-review

**Spec coverage:** D1 → Task 1; D2 → Task 2; D3+D4 → Task 3; E (DeliveryDecision folded — the
focus-guard branch in `deliver()` is already covered by existing `StrategySelectionTests` +
`deliver`'s own safety-net, and D2 covers the finish-recording exit paths, so no separate
`DeliveryDecision` unit is added; EngineLoadDecision → Task 4); F (trim decision) → Task 5;
D5 → Task 6; D6 → Task 7; verification → Task 8. Spec's "drop redundant Part-3 tests" honored
(no new streaming-degrade or LLM-lose-text tests — those exist).

**Placeholder scan:** the only deferred value is `ParakeetBackend.batchMinimumDuration` (0.16 s),
which the spec designates empirical; Task 6 gives a concrete default **and** the exact repro to
pin it. No other TBD/TODO.

**Type consistency:** `ModelRowStatus`/`ModelRowEvent`/`ModelRowState.reduce`,
`TerminalDelivery`/`TerminalDeliveryDecision.decide(finalText:cleanedText:)`,
`RecordingGate.handle(_:mode:)` + `Action` cases (`beginStart`/`goLive`/`finish`/`abortToIdle`/`none`),
`EngineLoadDecision.shouldApply`/`fallback`, `StreamStopPolicy.trimAtStop`/`needsLazyTrim`,
`ParakeetBackend.isBelowBatchMinimum` — all names are consistent between their defining task
and their use in `AppController`.
