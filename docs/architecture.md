# fabulous — architecture

## Shape

A menu bar app (`LSUIElement`) built as a SwiftPM package of five library
modules plus one executable. Feature modules depend only on `FabCore`; the
executable is the only place everything meets. `TranscriptionEngine` is the
only module that imports WhisperKit, so swapping/adding ASR backends never
touches capture, hotkeys, or injection.

```
              ┌─────────────────────────────────────────────────┐
              │                 FabulousApp (exe)               │
              │ AppController · StatusItem · Settings · Overlay │
              │        Onboarding · SettingsStore · Permissions │
              └─┬────────┬────────────┬─────────────┬─────────┬─┘
                │        │            │             │         │
         HotkeyEngine AudioCapture TranscriptionEngine TextInjector HistoryStore
                │        │            │             │         │
                └────────┴──────┬─────┴─────────────┴─────────┘
                             FabCore
              (AudioBuffer · Transcript · ModelDescriptor/Catalog ·
               TextPostProcessor · ReplacementDictionary)
```

### Dictation data flow

```
hold hotkey ──► AudioRecorder.start()          (AVAudioEngine input tap)
                 │  tap thread: device format ──AVAudioConverter──► 16 kHz mono f32
release ──────► AudioRecorder.stop()
                 │  EnergyVAD trims leading/trailing silence
                 ▼
            TranscriptionBackend.transcribe(AudioBuffer)   (WhisperKit, CoreML/ANE)
                 ▼
            TextPostProcessor pipeline        (passthrough → dictionary → LLM later)
                 ▼
            TextInjector.inject(text)         (strategy chain, below)
```

The `AppController` state machine gates everything:
`needsPermissions → loadingModel → idle ⇄ recording → transcribing → idle`,
with a self-clearing `failed` state so errors never wedge the hotkey.

## Module notes

### HotkeyEngine
Primary: a **CGEventTap** created as an *active* tap (`.defaultTap`). Active
taps work with the Accessibility permission we already require for injection;
a listen-only tap would additionally require Input Monitoring. Two trigger
kinds (`HotkeyTrigger`):

- **Modifier-hold** (Right ⌥, Fn/Globe, …) — matched on `flagsChanged` by
  hardware key code, since flag masks don't carry left/right. Always passed
  through to the system.
- **Key chord** (⌥Space, ⇧⌘F5, …) — matched on `keyDown`/`keyUp` with a
  side-insensitive modifier set (`ChordModifiers`). Matched events (and
  their autorepeats) are *swallowed* by returning nil from the tap callback,
  so the chord doesn't also type into the focused app.

The tap re-arms itself on `tapDisabledByTimeout`. Fallback when the tap
can't be created: `NSEvent.addGlobalMonitorForEvents` (no swallowing there).
Push-to-talk and toggle modes are interpreted by `AppController`; the monitor
only reports raw press/release transitions. The settings window records new
hotkeys with a local event monitor (`KeyCaptureSession`) while the global
monitor is suspended.

### AudioCapture
`AudioRecorder` is an actor owning an `AVAudioEngine`. The render tap
resamples on the audio thread (`TapProcessor` + `AVAudioConverter`) straight
to 16 kHz mono Float32 and accumulates under a lock — no buffers cross a
concurrency boundary. Default-device changes (AirPods mid-session) arrive as
`AVAudioEngineConfigurationChange`; the recorder re-taps with the new format
and the converter is rebuilt, keeping already-captured samples. Silence
trimming sits behind the `VoiceActivityDetecting` protocol (named to dodge
WhisperKit's `VoiceActivityDetector` class): `EnergyVAD` (frame RMS +
padding) is the always-available default, and `SileroVAD` (CoreML, 512-sample
/ 32 ms chunks, CPU-only) replaces it at runtime once its ~1 MB model is on
disk — `SileroVADInstaller` (app layer) fetches it from the
FluidInference/silero-vad-coreml HF repo into
`…/fabulous/models/vad/silero_vad.mlmodelc/` with the same
all-components-or-not-installed rule as ASR models. `SileroVAD` keeps an
RMS pre-gate (~0.0005) in front of the model: the network scores pure
digital silence as ~0.76 speech probability, so all-zero chunks (including
the zero-padded final partial chunk) must never reach it. Any prediction
failure falls back to `EnergyVAD` — trimming must never lose a dictation.
If no chunk reads as speech, transcription is skipped entirely.

### TranscriptionEngine
`TranscriptionBackend` is the seam:

```swift
protocol TranscriptionBackend: Sendable {
    func load(model: ModelDescriptor) async throws
    func transcribe(_ audio: AudioBuffer, language: Language?) async throws -> Transcript
    func unload() async
}
```

Backends: **WhisperKit** (shipped; `large-v3-turbo` recommended default,
`small`/`base` for smaller footprints), **Apple SpeechAnalyzer** (shipped
phase 4, experimental, macOS 26+ behind `#available` and a Settings →
General engine toggle; WhisperKit stays the default), **Parakeet via
FluidAudio** (parked; only if SpeechAnalyzer disappoints).

`SpeechAnalyzerBackend` differs from WhisperKit in ownership: model assets
belong to the OS (`AssetInventory` reserve + install on `load`; nothing
under our models directory, nothing in the Models tab), and keep-warm is
expressed as `SpeechAnalyzer.Options.modelRetention = .processLifetime`
rather than holding an object. A transcriber/analyzer pair is created per
utterance — modules are single-use; the retained model makes that cheap.
Engine choice is persisted as `TranscriptionEngineKind` in settings; any
Apple Speech load failure reverts the preference and reloads Whisper so
dictation never dies. History rows record which engine produced them via
the existing `modelID` column (`apple-speech`), which is what makes the A/B
dogfooding comparison decidable.

**Model management** is split from loading: `ModelManager` (actor) owns the
on-disk lifecycle — download with progress, delete, size accounting —
against the hub snapshot layout codified in `ModelLayout`
(`<base>/models/argmaxinc/whisperkit-coreml/<variant>/`). A model counts as
installed only when all required CoreML components exist, so interrupted
downloads read as not-installed and re-running a download resumes/repairs it
(the hub client skips files that already match the remote manifest — this
doubles as integrity verification). `WhisperKitBackend.load` prefers the
installed folder (pure local load, works offline) and only reaches for the
network when the model isn't on disk. Downloads land in
`~/Library/Application Support/fabulous/models/`; never bundled. Offline is
detected both reactively (URLError classification → a typed `.offline`
error) and proactively (`NWPathMonitor` banner in the Models tab).

### TextInjector — the strategy chain

Getting text into an arbitrary frontmost app is the hardest part to get
right. Three strategies, tried in order, each failure falling through to the
next-less-clean one:

1. **AX insert** — set `kAXSelectedText` on the focused `AXUIElement`.
   Replaces the selection or inserts at the caret; no clipboard pollution.
   Fails cleanly when the element doesn't support it (checked via
   `AXUIElementIsAttributeSettable`) — but some apps lie and report success
   without inserting, hence per-app overrides.
2. **Paste simulation** — save plain-text clipboard → set transcript →
   synthesize ⌘V (`CGEvent`) → restore the clipboard after 300 ms *only if
   the change count still matches* (someone else may have copied meanwhile).
   Known limitation: non-string clipboard content is not preserved.
3. **Keystroke synthesis** — `CGEvent` unicode typing in ≤20-UTF-16-unit
   chunks with small delays. Last resort for apps that block paste.

Selection is split from execution for testability: `StrategySelector` is a
pure function of an `InjectionContext` (frontmost bundle ID, secure-input
flag, accessibility trust) → either a strategy chain or a refusal. Hard
rules: **secure input active** (password fields) → refuse, never type;
no Accessibility → refuse with guidance. Per-app overrides start the chain
lower (terminals default to paste — AX insertion into terminal emulators is
unreliable); the chain never promotes back upward.

### UI layer
Status item + menu (AppKit); onboarding window (SwiftUI in an
`NSHostingController`) with 1 Hz permission polling — Accessibility has no
change notification API.

**Settings window** (SwiftUI, three tabs): General (hotkey recorder, PTT vs
toggle, microphone picker by Core Audio UID, launch-at-login via
`SMAppService`), Models (catalog with download progress / use / delete,
offline banner), History (toggle, recent list, clear). Views are
presentation-only: state flows in via `@Observable` models
(`SettingsStore`, `ModelListModel`, `ConnectivityMonitor`), effects flow out
through a `SettingsActions` closure bundle into `AppController`.

**Recording overlay**: a borderless, *non-activating* `NSPanel`
(bottom-center of the screen the mouse is on) that joins all Spaces, ignores
the mouse, and never becomes key — the target app must keep focus or
injection would break. Shows a smoothed input-level meter while recording
(50 ms polls of `AudioRecorder.currentLevel`) and a spinner while
transcribing.

**History**: GRDB/SQLite at `~/Library/Application Support/fabulous/
history.sqlite`, capped at 500 entries (pruned on insert). Text only — audio
is never persisted. The toggle simply stops `record` calls; Clear History
deletes all rows.

**Dictation metrics** live in the same database but a separate table
(`dictationMetrics`, cap 5000): per-dictation stage timings + engine ID,
numbers only. Deliberately decoupled from the history toggle and Clear
History — the transcript text is the privacy-sensitive part; the latency
record is the evidence the engine-default decision runs on.
`HistoryStore.latencyStats(engineID:)` computes nearest-rank p50/p90 over
the newest 500 rows per engine, shown as a second menu line and refreshed
on every dictation and engine switch.

### Post-processing (v1.5 interface, shipped now)
`TextPostProcessor` — `process(String) async throws -> String`. Shipped:
`PassthroughPostProcessor`, `PostProcessingPipeline`,
`ReplacementDictionary` (word-boundary-safe via lookarounds, case-insensitive
by default). The local-LLM cleanup pass slots in as another stage; nothing
upstream changes.

## Concurrency model (Swift 6 strict, zero warnings)

| Component | Isolation |
|---|---|
| `AudioRecorder` | actor; engine confined, tap thread touches only `TapProcessor` |
| `TapProcessor` | `@unchecked Sendable`, lock-guarded accumulator; documented invariant |
| `WhisperKitBackend`, `ModelManager` | actors; non-Sendable `WhisperKit` confined (retroactive `@unchecked Sendable` to satisfy region checks) |
| `HistoryStore` | `Sendable` class over GRDB's `DatabaseQueue` (which serializes) |
| `HotkeyMonitor`, `TextInjector`, UI | `@MainActor` |
| `SettingsStore`, `ModelListModel`, `OverlayModel`, `ConnectivityMonitor` | `@MainActor @Observable` |
| `FabCore` types | `Sendable` value types |

CGEventTap callback: Sendable fields are extracted from the CGEvent before
`MainActor.assumeIsolated` (the tap's run-loop source lives on the main run
loop).

## Decisions

- **SwiftPM, no XcodeGen** (both were allowed): zero generation step, Xcode
  opens `Package.swift` directly, and `scripts/build.sh` assembles the .app
  bundle (Info.plist, PkgInfo, resource bundles, codesign). Tradeoff: bundle
  assembly is ours to maintain; acceptable for one small script.
- **No sandbox in v1**: CGEventTap and cross-app AX APIs are the product;
  they don't work sandboxed. Currently distributed unsigned (ad-hoc signed).
  Developer ID + notarization + hardened runtime remains the path if a
  certificate is ever obtained; scripts/build.sh already supports it via
  CODESIGN_IDENTITY. Minimal entitlements (audio-input only), no network
  beyond model downloads.
- **arm64 only**: `swift build --arch arm64`; no Intel slice, no Rosetta.
- **Active (not listen-only) event tap**: avoids needing Input Monitoring on
  top of Accessibility. The tap passes all events through untouched.
- **Refuse over degrade for secure input**: typing into password fields is a
  correctness *and* trust issue; fabulous visibly declines instead.

## Non-functional budgets

- Hotkey-release → text inserted: **< 1.5 s** for a 10 s utterance on M1
  (Parakeet target; Whisper base on ANE is in range after first-run CoreML
  specialization). The menu bar shows a processing state when exceeded.
- Idle memory: **< 150 MB** with model unloaded; idle-unload planned
  (`unload()` already on the protocol).
- Privacy: audio buffers are zeroed after transcription (`AudioBuffer.zero()`);
  transcripts leave memory only via injection (and the opt-in history, later).

## Testing

Unit: VAD trimming, resampling (rate/downmix/energy/streaming continuity),
replacement dictionary, strategy selection — `swift test`, Swift Testing.

End-to-end (phase 4, `Tests/PipelineTests`): capture-format buffers through
TapProcessor → VAD → a contract-checking fake `TranscriptionBackend` →
`ReplacementDictionary` → `StrategySelector`, plus the silent-recording
short-circuit and secure-input refusal paths. Runs unconditionally in
`swift test`.

Conditionally-run integration tests (skip cleanly when preconditions
missing): `SileroVADTests` needs the VAD model installed;
`SpeechAnalyzerBackendTests` runs the real Apple Speech engine over
`say`-synthesized audio behind `FAB_REAL_ASR=1` (downloads OS assets, macOS
26+ only).
