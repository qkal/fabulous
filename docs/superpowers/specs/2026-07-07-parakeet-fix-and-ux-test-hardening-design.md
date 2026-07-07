# Parakeet download fix + UX-invariant test hardening

**Date:** 2026-07-07
**Status:** Design — awaiting review
**Scope:** C+ (fold-all): fix the confirmed bugs the download investigation surfaced, and
convert the app's untested `@MainActor` orchestration invariants into pure, tested
decision logic in `FabCore`.

> Every load-bearing claim below was adversarially verified against the source by an
> independent agent (44-agent verification pass). `REFUTED` findings are excluded.
> File:line anchors are from that pass; treat them as "as of 2026-07-07" and re-confirm
> during implementation.

---

## 1. Summary

The user reported "can't run/test the Parakeet model — download fails/stuck." Investigation
found the Parakeet model is **fully downloaded and complete on disk** (`ParakeetLayout.isInstalled == true`);
the bytes-to-disk path works. The real defect is a **UI state-machine deadlock**: a
finished download is never transitioned to a terminal "installed" state in-session, so the
Models-tab row is stuck at a full 100% bar forever (until app restart).

Verifying that root cause turned up **four more confirmed defects** — including a
**blocker-severity silent-transcript-loss hole** — plus corrections showing half of the
originally-planned test work is already covered. This spec fixes all confirmed defects and
adds the tests that would have caught them, by extracting the relevant decisions into pure
`FabCore` units.

---

## 2. Root cause: the download-stuck deadlock (CONFIRMED)

- `refreshModelList()` is the **only** code that sets a row to `.installed`/`.active`
  (`AppController.swift:315–331`), and it unconditionally `continue`s past any row currently
  `.downloading` (`:317–318`, *"don't clobber an in-flight download row"*).
- On success, `ModelManager.download` emits `progress(1.0)` (parakeet `:101`, whisper `:120`)
  but sets **no** terminal row status; the last row write is `noteDownloadProgress` →
  `modelList.update(id, .downloading(1.0))` (`:311`). The `fraction >= 1` disjunct in the
  progress gate (`:309`) admits `1.0` unconditionally, so the row lands at exactly
  `.downloading(1.0)` — a **full bar that never flips**.
- A just-finished download is byte-indistinguishable from an in-flight one, so the
  post-download `refreshModelList()` skips it. The success transition never fires in-session.

**Verified refinements:**
- **Not parakeet-specific** — a fresh in-session Whisper Models-tab download sticks identically.
  Whisper only *appears* fine because it was installed before the user watched a live download.
- **All three entry points** reach it: General → engine toggle (`SettingsStore:57–61` →
  `onEngineChanged` → `loadParakeet`), Models-tab **Download** button (`:345–349`), Models-tab
  **Use** (`:358–368`). The trailing `refreshModelList()` in each path does not rescue the row.
- **Restart clears it** — `ModelListModel.items` re-init to `.notInstalled` every launch
  (`:27–29`); nothing is persisted. The stuck state is purely in-session.
- **Zero test coverage** — no test imports `FabulousApp` or exercises the status machine.

---

## 3. Confirmed defects to fix

| # | Defect | Severity | Anchor |
|---|--------|----------|--------|
| D1 | **Download-stuck deadlock** (general: all models, all 3 entry points, sticks at 100%) | High | `AppController:311/315–331`, `ModelManager:101/120` |
| D2 | **Silent transcript loss** — safety net exists only in `deliver()` (`:705/721/724`), but `finishRecording` has **3 other exit paths that drop text with no clipboard/overlay/history**, incl. empty-after-cleanup `guard !text.isEmpty else { state=.idle; overlay.hide(); return }` (`:659–665`) | **Blocker** | `AppController:577–699`, `safetyNet:729–734` |
| D3 | **Fast PTT tap → recorder runs forever** — `beginRecording` sets `state=.recording` at `:446` *after* `await recorder.start()` (`:430`); a `hotkeyReleased` (`:419`) arriving during that await is dropped, so the stop never happens | High | `AppController:424–446`, `:408–421` |
| D4 | **Toggle double-finish** — `finishRecording` has no `state==.recording` guard (`cancelRecording` has one at `:547`); two quick toggles double-fire the finish path | Medium | `AppController:577` |
| D5 | **Parakeet short-utterance failure** — a brief utterance: streaming returns empty → `finalTranscript` falls back to batch (`StreamingTranscription:52–71`) → batch can throw `ASRError.invalidAudioData` on the too-short buffer (`ParakeetBackend.transcribe` only guards `!audio.isEmpty`, `:108`) | Medium (PARTIAL: threshold needs repro) | `ParakeetBackend:99–139` |
| D6 | **Offline misclassified** — `ModelManager.isOffline` only matches `URLError` (`:154–163`); FluidAudio/HuggingFace downloads throw non-`URLError` types, so a network failure during Parakeet download surfaces as a generic error instead of the friendly "Offline — using Whisper" | Low | `ModelManager:154–163` |

**Not defects (verified clean):** Parakeet vocab filename (`parakeet_vocab.json` used by both
install-check and loader), v3/EOU folder names, and EOU download destination all match
FluidAudio 0.15.4 exactly. No install/load bug — D5 is the only Parakeet runtime issue.

---

## 4. Architecture

Extract the pure **decisions** out of `AppController` into `FabCore` (no AppKit, no side
effects — already the home of `DeliveryMethod`, `DictationMetrics`, `ModelDescriptor`,
`TranscriptionEngineKind`). `AppController` keeps the **effects** and becomes thin: build an
event → call a pure reducer/decision → run the returned effect.

New pure `FabCore` units:

1. **`ModelRowState`** — reducer `(status, event) → status`. Fixes D1.
2. **`TerminalDeliveryDecision`** — `(transcript, rawText, wasInjected, isScratchThat) → outcome`
   guaranteeing non-empty-not-injected text always reaches the safety net. Fixes D2.
3. **`DeliveryDecision`** — `(focusStillValid, strategyResult) → .inject(DeliveryMethod) | .safetyNet(notice)`.
   Makes the focus-guard + strategy-failure branch of `deliver()` testable.
4. **`EngineLoadDecision`** — `(requestedEngine, currentState, failure) → (revertTo, mustReloadWhisper, allowed)`.
   Encodes revert-to-Whisper + the "no-op unless idle/failed" gate. **Decision only** — the
   actual backend load stays in `AppController` (it's saturated with `WhisperKitBackend` /
   `ParakeetBackend` / `any TranscriptionBackend` types FabCore must not import).

**No new target.** Verified: `TranscriptionEngineKind` (`ModelDescriptor.swift:64`) and
`DeliveryMethod` (`DictationMetrics.swift:22`) already live in `FabCore`; the only move is
un-nesting `ModelListModel.Status` from its `@Observable` class into a standalone pure enum
(cases carry only `Double`/`String` — trivially `Sendable`, no AppKit). `ModelListModel`
stays in `FabulousApp` as the `@Observable` shell that holds `[Item]` and delegates every
status transition to `ModelRowState`. Keep `Item` and `Status` co-located (Item references
`FabCore.ModelRowStatus`); `SettingsView` reads `Status` in three places (`:51/301/341/360`)
and only needs the type re-exported.

---

## 5. Workstream A — Model-row state reducer (fixes D1)

**`FabCore/ModelRowState.swift`** — pure:

```
enum ModelRowStatus: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
    case failed(String)
}

enum ModelRowEvent {
    case downloadStarted
    case progress(Double)
    case downloadSucceeded(isActive: Bool)
    case downloadFailed(String)
    case reconcile(installed: Bool, isActive: Bool)   // disk truth
}

enum ModelRowState {
    static func reduce(_ status: ModelRowStatus, _ event: ModelRowEvent) -> ModelRowStatus
}
```

Transition rules (the fix + the precedence the design must pin):

- `downloadStarted` → `.downloading(0)`
- `progress(f)` → `.downloading(f)` **only if currently `.downloading`**; otherwise unchanged
  (a late progress tick can't resurrect a finished/failed row)
- `downloadSucceeded(isActive)` → `isActive ? .active : .installed` — **this is the fix**; the
  success flip no longer depends on `reconcile`
- `downloadFailed(msg)` → `.failed(msg)`
- `reconcile(installed, isActive)`:
  - current `.downloading` → **unchanged** (genuinely in-flight; the success event owns the flip)
  - current `.failed` → **unchanged** (preserve the failure message — reconcile must not
    regress `.failed → .notInstalled`)
  - otherwise → `installed ? (isActive ? .active : .installed) : .notInstalled`

**Wiring:** `AppController.downloadModel` emits `downloadSucceeded(isActive:)` on success
(computing `isActive` from `activeModelID`) at **every** call site (`:268/284`, `:345–349`).
`refreshModelList` becomes a `reconcile` sweep through the reducer, so its "skip downloading"
special-case is subsumed by the reducer's `reconcile` rule (no more ad-hoc `continue`).

---

## 6. Workstream B — Safety-net completeness (fixes D2, blocker)

**Invariant:** any non-empty transcript that isn't injected must reach `safetyNet`
(clipboard + overlay). Today only `deliver()` honors it; `finishRecording` bypasses it on
empty-after-cleanup and on error exits.

**`FabCore/TerminalDeliveryDecision.swift`** — pure:

```
enum TerminalDelivery: Equatable {
    case inject                 // hand to the injector
    case safetyNet(String)      // non-empty text, not injectable → clipboard + notice
    case dropSilently           // legitimately empty (true scratch-that, or never had text)
}

enum TerminalDeliveryDecision {
    static func decide(text: String, rawText: String?, isScratchThat: Bool) -> TerminalDelivery
}
```

- non-empty `text` → `.inject`
- empty `text` but non-empty `rawText` and **not** `isScratchThat` → `.safetyNet(rawText)`
  (cleanup/replacement swallowed real speech — never drop it)
- empty and (`isScratchThat` or no raw) → `.dropSilently`

**Wiring:** `finishRecording`'s empty-guard (`:659–665`) and its error/fallback exits route
through this decision instead of returning early; `.safetyNet` calls the existing
`safetyNet(_:notice:)`. This preserves the LLM-cleanup invariant (empty accepted only for
"scratch that", already tested in `FoundationModelPostProcessorTests`) while closing the
deterministic-post-processor and error holes.

---

## 7. Workstream C — Recording lifecycle guards (fixes D3, D4)

- **D4 (toggle double-finish):** add `guard state == .recording else { return }` at the top of
  `finishRecording` (mirror `cancelRecording:547`). Cheap, high-value.
- **D3 (fast PTT tap):** close the press/release race. `hotkeyPressed` transitions to an
  intent state synchronously (e.g. `.starting`) *before* the async `beginRecording`;
  `hotkeyReleased` arriving during `recorder.start()` sets a pending-stop that
  `beginRecording` checks immediately after `start()` returns and, if set, finishes at once.
  (Exact state naming settled in the plan; the observable contract is: *a release is never
  lost, no matter how fast it follows the press*.)

Both are made testable via a fake `AudioRecorder` seam in `PipelineTests` (see §10). The pure
part of D3/D4 (the "given press/release ordering, what should happen" predicate) can live in a
small `RecordingGate` helper in `FabCore` if extraction stays clean; otherwise it's tested
through the fake recorder.

---

## 8. Workstream D — Parakeet robustness (fixes D5, D6)

- **D5 (short utterance):** add a minimum-duration guard to `ParakeetBackend.transcribe` — below
  the threshold, return an empty `Transcript` rather than letting FluidAudio throw
  `invalidAudioData`; and in the streaming→batch fallback, skip the batch retry when the buffer
  is below that threshold. **Threshold is empirical** — pin it with a repro (short `say`
  clips) during implementation; document the chosen value. Empty result then flows through
  Workstream B (`.dropSilently` for a genuinely empty short blip — no lost text, no crash).
- **D6 (offline classification):** broaden `ModelManager.isOffline` to also recognize
  FluidAudio/HuggingFace network errors (bridge via `NSError` domain/`NSURLErrorDomain`, or
  match FluidAudio's download error type) so a Parakeet download network failure surfaces the
  friendly "Offline — using Whisper" path. Keep conservative — only clear network signals map
  to offline.

---

## 9. Workstream E — Pure decision extraction (DeliveryDecision, EngineLoadDecision)

- **`FabCore/DeliveryDecision.swift`:** `(focusStillValid, strategyResult) →
  .inject(DeliveryMethod) | .safetyNet(notice)`. `AppController.deliver` builds the inputs and
  runs the effect. Returns the existing `FabCore.DeliveryMethod`.
- **`FabCore/EngineLoadDecision.swift`:** `(requested: TranscriptionEngineKind, state, failure)
  → (revertTo: TranscriptionEngineKind, mustReloadWhisper: Bool, allowed: Bool)`. Encodes:
  engine-load failure → revert to `.whisper` + reload; and the **gate** "an engine change is a
  no-op unless `state == .idle || isFailed(state)`" (`onEngineChanged:141`, `useModel:362`).
  `allowed == false` when the gate rejects. Backend loading stays in `AppController`.

---

## 10. Workstream F — Test plan (corrected)

**Drop as redundant (verified already covered):**
- LLM cleanup never loses text — fully covered in
  `FoundationModelPostProcessorTests.swift:68–95` (model-error / timeout / empty-without-command
  / trailing-scratch-that / mid-utterance-scratch-that / empty-input all → raw). No new work.
- Streaming→batch degrade **boolean** — covered in `StreamingPipelineTests.swift:49–102`
  (session-wins / finish-failure / empty-streamed / missing-session). Keep as-is.

**New tests (real gaps):**

| Target | Tests |
|--------|-------|
| `FabCoreTests/ModelRowStateTests` | deadlock replay (`started→progress→succeeded→reconcile` ⇒ `installed`/`active`); `reconcile(installed:false)` on `.failed` ⇒ **stays** `.failed`; `reconcile` on `.downloading` ⇒ stays downloading; late `progress` after success ⇒ ignored; all-three-entry-point sequences |
| `FabCoreTests/TerminalDeliveryDecisionTests` | non-empty ⇒ inject; empty+raw+not-scratch ⇒ safetyNet(raw); empty+scratch ⇒ dropSilently; empty+no-raw ⇒ dropSilently |
| `FabCoreTests/DeliveryDecisionTests` | focus-invalid ⇒ safetyNet; all-strategies-fail ⇒ safetyNet; success ⇒ inject(method) |
| `FabCoreTests/EngineLoadDecisionTests` | load-fail ⇒ revert `.whisper` + mustReload; gate rejects while `.recording`/`.loadingModel`; allowed while `.idle`/`.failed` |
| `PipelineTests` (fake `AudioRecorder`) | D3: release during `start()` ⇒ recorder stops; D4: double toggle-finish ⇒ single finish; finishRecording empty-after-cleanup with non-empty raw ⇒ safety net fired |
| `PipelineTests` (extract trim decision) | the `audioIsRaw` branch (`AppController:623–639`): raw buffer ⇒ trimmed once before batch; already-trimmed ⇒ used as-is. **Correct the seam** — this lives in `finishRecording`, not `StreamingDictation.finalTranscript` |
| `TranscriptionEngineTests/ParakeetBackendTests` | D5: below-threshold buffer ⇒ empty `Transcript`, no throw (pure min-duration guard); real-engine short-clip test gated by `FAB_REAL_ASR` |
| `TranscriptionEngineTests` | D6: a non-`URLError` network error ⇒ `isOffline == true` |

All existing tests stay green; zero new warnings under Swift 6 strict concurrency.

---

## 11. Non-goals (YAGNI)

- No new SwiftPM target (FabCore fits — verified).
- No UI/snapshot tests; no rewrite of `AppController`'s effect execution.
- No touching the download **transport** (bytes-to-disk verified correct).
- No new tests for invariants verified **held**: keep-warm/no-idle-unload, paste clipboard-restore
  defusing, screen-text-logged-count-only privacy. (Held today; noted as future stretch, not core.)
- No Parakeet install/load changes beyond D5 (install/load verified correct).

---

## 12. Risks

- **D3 recording race** touches timing-sensitive event-tap code; mitigated by the fake-recorder
  test that forces the release-during-start ordering deterministically.
- **`Status` un-nest** touches `SettingsView` (3 read sites); mechanical, contained.
- **D5 threshold** is empirical — must be pinned with a real repro, not guessed; documented in
  the plan and code comment.
- **Reconcile precedence** is the subtle core of D1 — the `.failed`/`.downloading` rules must be
  exactly as specified or the deadlock/regression returns; the reducer tests pin all branches.

---

## 13. Implementation order (for the plan)

1. D4 guard + D1 reducer (+ tests) — smallest, unblocks the reported symptom.
2. D2 `TerminalDeliveryDecision` + wiring (+ tests) — the blocker.
3. D3 recording race (+ fake-recorder test).
4. E extractions (`DeliveryDecision`, `EngineLoadDecision`) (+ tests).
5. D5 + D6 Parakeet robustness (+ tests).
6. F remaining tests + trim-decision extraction.

Each step is TDD: failing test that reproduces the defect → fix → green.

## 14. Verification (definition of done)

- `swift build --arch arm64` clean, zero warnings.
- `swift test` green (incl. new suites; real-engine suites still auto-skip without `FAB_REAL_ASR`/models).
- Manual smoke: download a model in Models tab → row flips to **installed** in-session (no restart);
  fast PTT tap → no stuck recorder; empty/short dictation → transcript never silently vanishes.
