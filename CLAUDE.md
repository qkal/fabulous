# fabulous — agent notes

Native macOS voice dictation menu bar app. Hold hotkey → record → on-device
ASR → inject text into frontmost app. Swift 6 strict concurrency, SwiftPM
only (no .xcodeproj — do not generate one).

## Commands

```sh
swift build --arch arm64      # compile (arm64 only; never add x86_64)
swift test                    # unit tests (Swift Testing, not XCTest)
scripts/build.sh              # → build/fabulous.app (assembles bundle + codesigns)
CONFIG=debug scripts/build.sh # debug bundle
open build/fabulous.app       # run (menu bar app, no Dock icon)
scripts/make-dmg.sh <version>  # → build/fabulous-<version>.dmg (needs create-dmg)
```

Build treats warnings in our targets as things to fix — the codebase compiles
with zero warnings under strict concurrency; keep it that way.

## Layout

SwiftPM targets, one directory each under `Sources/`:

- `FabCore` — shared value types (`AudioBuffer`, `Transcript`,
  `ModelDescriptor`), `TextPostProcessor` pipeline, `ReplacementDictionary`,
  paths. No AppKit imports.
- `AudioCapture` — `AudioRecorder` actor (AVAudioEngine tap → 16 kHz mono via
  `AudioResampler`/`TapProcessor`), silence trimming behind
  `VoiceActivityDetecting`: `EnergyVAD` default, `SileroVAD` (CoreML)
  swapped in at runtime once its model is installed.
- `HotkeyEngine` — `HotkeyMonitor` (@MainActor): CGEventTap primary,
  NSEvent global monitor fallback. `HotkeySpec` = mode + modifier.
- `TranscriptionEngine` — `TranscriptionBackend` protocol,
  `WhisperKitBackend` actor, `SpeechAnalyzerBackend` actor (macOS 26+,
  OS-managed assets), `ParakeetBackend` actor + `ParakeetLayout`/`ParakeetInstaller`
  (Parakeet TDT 0.6b v3 batch + EOU 120M streaming via FluidAudio),
  `ModelManager` actor + `ModelLayout` (install/verify/delete on disk;
  hub snapshot path shape lives here).
- `TextInjector` — `StrategySelector` (pure, tested) picks
  axInsert → paste → keystrokes chain; `TextInjector` (@MainActor) executes.
- `ScreenReader` — screen-context harvest: `ScreenContextReader` walks the
  dictation-target window's AX tree (existing Accessibility grant, no
  Screen Recording), `TextHarvester` bounded walk core (pure, tested),
  `ScreenContextPolicy`. Terms feed SpeechAnalyzer contextual strings +
  LLM cleanup vocabulary.
- `HistoryStore` — GRDB/SQLite transcript history (`TranscriptEntry`),
  cap-pruned on insert; only module importing GRDB.
- `PostProcessing` — LLM transcript cleanup: `FoundationModelPostProcessor`
  actor (Apple Foundation Models, macOS 26), `CleanupPromptBuilder` (pure),
  `PostProcessingAvailability`; only target importing FoundationModels.
- `FabulousApp` — executable: `AppController` state machine, status item,
  settings window (General/Models/History tabs), hotkey recorder
  (`KeyCaptureSession`), overlay pill (`OverlayController`), onboarding,
  permissions, `SettingsStore` (UserDefaults), `ConnectivityMonitor`.

Dependency rule: feature modules depend only on FabCore; only FabulousApp
sees everything. `TranscriptionEngine` is the only target importing WhisperKit
and FluidAudio.

## Gotchas (hard-won)

- **TCC + signing**: ad-hoc signatures change every rebuild → macOS revokes
  Microphone/Accessibility grants. `scripts/make-dev-cert.sh` (run once)
  creates a self-signed "fabulous-dev" identity in a dedicated keychain
  (`security` import needs `openssl pkcs12 -legacy` on OpenSSL 3!);
  `build.sh` auto-detects it. `CODESIGN_IDENTITY` env overrides.
  CSSMERR_TP_NOT_TRUSTED from `find-identity -v` is fine — codesign still
  signs, and TCC only needs signature stability. If `build.sh` fails with
  `errSecInternalComponent`, the keychain locked (sleep does this despite
  no-auto-lock settings): `security unlock-keychain -p fabulous-dev-local
  ~/Library/Keychains/fabulous-dev.keychain-db`.
- **FluidAudio name collisions**: it declares its own `Language` (vs
  `FabCore.Language`), and it ALSO ships `public struct FluidAudio {}` as a
  deliberate namespace shim — so `FluidAudio.Language(...)` does NOT compile
  once both modules are imported in one file (resolves to 'member of struct
  FluidAudio', not the module). Fix: add `import enum FluidAudio.Language`
  alongside the plain `import FluidAudio`, then refer to it as bare `Language`;
  qualify FabCore's side as `FabCore.Language` as usual. **Parakeet streams
  with a different model**: streaming = EOU 120M, batch/fallback = TDT v3;
  both install under `models/models/FluidInference/…` via `ParakeetInstaller`,
  checked by `ParakeetLayout` (NOT `ModelLayout`), and the on-disk leaf
  directory names are FluidAudio's own `Repo.folderName` values (e.g.
  `parakeet-tdt-0.6b-v3`, `parakeet-eou-streaming/160ms`) — NOT the
  HuggingFace repo IDs; FluidAudio's own load/download calls discard whatever
  leaf name you pass and re-derive it from `folderName` internally.
- **`AudioBuffer` name collision**: CoreAudio has one too. In files importing
  AVFoundation, write `FabCore.AudioBuffer`.
- **WhisperKit's `EnergyVAD`**: WhisperKit also declares `EnergyVAD`. Ours
  lives in `AudioCapture`; never import WhisperKit and AudioCapture in the
  same file without qualifying.
- **`kAXTrustedCheckOptionPrompt`** is a C global var → banned under strict
  concurrency. Use the literal string `"AXTrustedCheckOptionPrompt"`.
- **CGEventTap callback**: runs on the main run loop; extract Sendable fields
  from the CGEvent *before* `MainActor.assumeIsolated` (CGEvent isn't
  Sendable).
- **`WhisperKit` class isn't Sendable**: `WhisperKitBackend` confines it and
  declares `@retroactive @unchecked Sendable` — keep instances inside that
  actor.
- **Event tap needs Accessibility, not Input Monitoring**: we create a
  `.defaultTap` (active, pass-through), which works with the Accessibility
  grant we need anyway. A `.listenOnly` tap would drag in a third permission.
- Models download to
  `~/Library/Application Support/fabulous/models/models/argmaxinc/whisperkit-coreml/<variant>/`
  (the double `models` is ours + the hub's repo-type segment — encoded in
  `ModelLayout`, don't hardcode elsewhere). First load also pays one-time
  CoreML specialization (minutes on some machines) — that's the `prewarm`
  option, not a hang.
- **Hotkey chords are swallowed** by returning nil from the event tap
  callback; modifier-hold events always pass through. The NSEvent fallback
  can't swallow. The tap listens to ALL key events (keyDown/keyUp/
  flagsChanged) regardless of trigger kind — Esc interception during
  recording needs keyDown even for modifier-hold specs.
- **Latency is measured, not assumed**: `DictationMetrics` (FabCore) is
  filled by `AppController.finishRecording`, surfaced in the menu + log, and
  persisted per dictation to the `dictationMetrics` table (HistoryStore,
  numbers only — independent of the history toggle, survives Clear History;
  the menu shows per-engine p50/p90 from it). Keep-warm is deliberate — do
  NOT add idle model unload without checking the phase-3 spec's reasoning
  (latency is the user's deal-breaker).
- **Transcripts must never be silently lost**: any non-injection path goes
  through `AppController.safetyNet` (clipboard + overlay notice). Preserve
  this invariant when touching delivery code.
- **`SMAppService` (launch at login)** fails when running the bare binary
  (`swift run`) — it needs a real .app bundle; the settings UI surfaces the
  error rather than crashing.
- The hub download client resumes/repairs partial downloads on re-run; a
  model is "installed" only if all `ModelLayout.requiredComponents` exist.
- **Silero VAD scores digital silence as speech**: the CoreML model returns
  ~0.76 probability on all-zero chunks. `SileroVAD` has an RMS pre-gate
  (~0.0005) in front of every prediction — do not remove it. Its model lives
  at `models/vad/silero_vad.mlmodelc/` (5 files, `SileroVADInstaller` in the
  app layer), a sibling of the hub-shaped ASR tree, NOT managed by
  `ModelLayout`.
- **SpeechAnalyzer assets are OS-owned**: `SpeechAnalyzerBackend.load` goes
  through `AssetInventory` (reserve locale + install); nothing appears under
  our models directory or in the Models tab. Keep-warm =
  `modelRetention: .processLifetime`; transcriber/analyzer are created per
  utterance (modules are single-use). An engine load failure must revert
  `settings.transcriptionEngine` to `.whisper` AND explicitly reload Whisper
  — `onEngineChanged` no-ops outside `.idle`/`.failed`.
- **SpeechAnalyzer biasing is `setContext`, not init**: plain
  `SpeechAnalyzer(modules:options:)` takes no `analysisContext:`; call
  `analyzer.setContext(AnalysisContext with .general contextualStrings)`
  after creation — it also works MID-SESSION on a running analyzer
  (that's how streaming gets screen terms without delaying start).
  Screen text itself is memory-only: never persist/log it verbatim
  (log term counts), and `TextHarvester` must keep skipping
  `AXSecureTextField` subtrees.
- **Async protocol witness vs default extension**: an actor method
  satisfying an `async` protocol requirement MUST be spelled `async`
  when the protocol also has a default-extension implementation —
  otherwise the compiler silently binds the no-op default and the actor
  method never runs (bit us on `setScreenTerms`; `ContextBiasing` has
  no default so its sync actor witness is fine).
- Real-engine tests are conditional: `FAB_REAL_ASR=1 swift test --filter
  SpeechAnalyzerBackendTests` runs the actual Apple Speech engine over
  `say`-synthesized audio; `SileroVADTests` auto-skip unless the VAD model
  is installed. `Tests/PipelineTests` (capture → decision e2e with a fake
  backend) always runs.
- **Streaming failures must degrade to the batch path** over the full
  untrimmed buffer — `StreamingDictation.finalTranscript` is the seam. The
  streaming path stops the recorder with `trimming: false`; do not "fix"
  that back to a trimmed stop.
- **LLM cleanup can only improve or no-op, never lose or invent text**: every
  failure path in `FoundationModelPostProcessor` (throw, timeout, guardrail
  refusal, empty output) returns the raw transcript, and `CleanupOutputGate`
  (pure, corpus-pinned) rejects model output that invents words — rejection
  also returns the raw transcript, with outcome `.rejected` in metrics/menu.
  Empty output is accepted only when the raw text contains "scratch that" —
  a whole-utterance scratch legitimately cleans to nothing. Fresh
  `LanguageModelSession` per dictation — session reuse accumulates context
  and leaks text across dictations.
- **Keystroke strategy can't type `\n`** via `keyboardSetUnicodeString`;
  `KeystrokeSegmenter` splits text and posts real Return key events between
  runs. Don't collapse that back into a single unicode-string post.

## State / roadmap

Done: vertical slice (hold hotkey → Whisper → inject); settings window with
hotkey recorder (modifier-hold + key chords, PTT/toggle), input device
picker, launch-at-login; model management (catalog large-v3-turbo/small/base,
download progress, delete, hot-swap, offline detection); bottom-center
recording overlay with level meter; transcript history (GRDB, cap 500,
toggle + clear); phase 3 "trustworthy daily driver": stable
local signing, per-dictation latency metrics in menu + log, sound cues,
Esc-cancels-recording, injection safety net (clipboard + overlay notice),
focus-change guard, replacements editor tab; phase 4 "faster engine":
SpeechAnalyzer backend behind a
Settings → General engine toggle (Whisper stays default — A/B measured
2026-07-03: streamed Apple Speech p50 475 ms / p90 591 ms vs Whisper
~2.5 s on comparable audio, but the user chose to keep Whisper default
for now; delivery/injection ≈370 ms is the next latency bottleneck),
Silero VAD with EnergyVAD fallback, end-to-end pipeline tests
(`Tests/PipelineTests`) + conditional real-engine tests; phase 5
"streaming": SpeechAnalyzer sessions
fed live during recording, overlay partials, batch fallback, `streamed`
metrics column; paper UI restyle: PaperTheme
tokens, frosted paper pill, paper settings/onboarding, theme switcher (Paper/Glass + System/Light/Dark appearance);
CI + dmg releases: GitHub Actions
build+test on push/PR (macos-26, pinned), tag push v* → unsigned dmg
attached to GitHub Release (create-dmg, version stamped from tag;
Info.plist stays 0.0.0-dev in git); LLM post-processing:
opt-in on-device cleanup via Apple
Foundation Models — fillers, punctuation, spoken commands (new line/paragraph,
scratch that, quote…unquote), vocabulary bias, app-name hint; raw transcript
kept in history (`rawText`) when cleanup changed it.
injection latency: paste clipboard
restore moved off the critical path (~370 ms → ~60 ms delivery),
per-dictation DeliveryMethod (axInsert/paste/keystrokes/safetyNet) in
metrics + menu "Inject" stats line;
per-app injection overrides: Apps
settings tab, AppOverride user entries layered over built-in terminal
defaults (user wins, delete reverts), injector selector swapped live;
Parakeet/FluidAudio backend: TDT 0.6b v3
batch + EOU 120M streaming, third engine picker option, gated Models-tab
management, shipped 2026-07-04, dogfood decision pending (stay-120M / hybrid
/ batch-only);
screen context: AX-harvested on-screen
vocabulary at record start → SpeechAnalyzer contextual strings + LLM
cleanup vocab; ScreenReader module; default-on toggle in General;
Whisper/Parakeet get the cleanup half only.
public-readiness packaging:
GPL-3.0 LICENSE, bundle-ID io.github.qkal.fabulous, PrivacyInfo.xcprivacy,
README rewrite, dependabot + dmg SHA-256, community-health files, AI-session
docs untracked (architecture.md kept). Repo-public flip is the deferred gated
step (pending maintainer go-ahead). DEFERRED to a future
"signing" workstream: Developer-ID signing, notarization, hardened runtime,
Sparkle auto-update, real screenshots (needs an Apple Developer account).
