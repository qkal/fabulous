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
```

Build treats warnings in our targets as things to fix — the codebase compiles
with zero warnings under strict concurrency; keep it that way.

## Layout

SwiftPM targets, one directory each under `Sources/`:

- `FabCore` — shared value types (`AudioBuffer`, `Transcript`,
  `ModelDescriptor`), `TextPostProcessor` pipeline, `ReplacementDictionary`,
  paths. No AppKit imports.
- `AudioCapture` — `AudioRecorder` actor (AVAudioEngine tap → 16 kHz mono via
  `AudioResampler`/`TapProcessor`), `EnergyVAD` silence trimming.
- `HotkeyEngine` — `HotkeyMonitor` (@MainActor): CGEventTap primary,
  NSEvent global monitor fallback. `HotkeySpec` = mode + modifier.
- `TranscriptionEngine` — `TranscriptionBackend` protocol,
  `WhisperKitBackend` actor, `ModelManager` actor + `ModelLayout`
  (install/verify/delete on disk; hub snapshot path shape lives here).
- `TextInjector` — `StrategySelector` (pure, tested) picks
  axInsert → paste → keystrokes chain; `TextInjector` (@MainActor) executes.
- `HistoryStore` — GRDB/SQLite transcript history (`TranscriptEntry`),
  cap-pruned on insert; only module importing GRDB.
- `FabulousApp` — executable: `AppController` state machine, status item,
  settings window (General/Models/History tabs), hotkey recorder
  (`KeyCaptureSession`), overlay pill (`OverlayController`), onboarding,
  permissions, `SettingsStore` (UserDefaults), `ConnectivityMonitor`.

Dependency rule: feature modules depend only on FabCore; only FabulousApp
sees everything. `TranscriptionEngine` is the only target importing WhisperKit.

## Gotchas (hard-won)

- **TCC + signing**: ad-hoc signatures change every rebuild → macOS revokes
  Microphone/Accessibility grants. `scripts/make-dev-cert.sh` (run once)
  creates a self-signed "fabulous-dev" identity in a dedicated keychain
  (`security` import needs `openssl pkcs12 -legacy` on OpenSSL 3!);
  `build.sh` auto-detects it. `CODESIGN_IDENTITY` env overrides.
  CSSMERR_TP_NOT_TRUSTED from `find-identity -v` is fine — codesign still
  signs, and TCC only needs signature stability.
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
  filled by `AppController.finishRecording` and surfaced in the menu + log.
  Keep-warm is deliberate — do NOT add idle model unload without checking
  the phase-3 spec's reasoning (latency is the user's deal-breaker).
- **Transcripts must never be silently lost**: any non-injection path goes
  through `AppController.safetyNet` (clipboard + overlay notice). Preserve
  this invariant when touching delivery code.
- **`SMAppService` (launch at login)** fails when running the bare binary
  (`swift run`) — it needs a real .app bundle; the settings UI surfaces the
  error rather than crashing.
- The hub download client resumes/repairs partial downloads on re-run; a
  model is "installed" only if all `ModelLayout.requiredComponents` exist.

## State / roadmap

Done: vertical slice (hold hotkey → Whisper → inject); settings window with
hotkey recorder (modifier-hold + key chords, PTT/toggle), input device
picker, launch-at-login; model management (catalog large-v3-turbo/small/base,
download progress, delete, hot-swap, offline detection); bottom-center
recording overlay with level meter; transcript history (GRDB, cap 500,
toggle + clear); phase 3 "trustworthy daily driver" (docs/specs/): stable
local signing, per-dictation latency metrics in menu + log, sound cues,
Esc-cancels-recording, injection safety net (clipboard + overlay notice),
focus-change guard, replacements editor tab.

Not yet built: Silero VAD (phase-3 stretch, slipped), Parakeet/FluidAudio
backend and streaming transcription (parked pending latency data),
SpeechAnalyzer backend (macOS 26+), per-app injection override settings UI,
LLM post-processing (interface exists: `TextPostProcessor`),
signed/notarized .dmg release pipeline. See docs/architecture.md and
docs/specs/phase-3-trustworthy-daily-driver.md.
