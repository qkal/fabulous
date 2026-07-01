# fabulous — architecture

## Shape

A menu bar app (`LSUIElement`) built as a SwiftPM package of five library
modules plus one executable. Feature modules depend only on `FabCore`; the
executable is the only place everything meets. `TranscriptionEngine` is the
only module that imports WhisperKit, so swapping/adding ASR backends never
touches capture, hotkeys, or injection.

```
                 ┌─────────────────────────────────────────┐
                 │            FabulousApp (exe)            │
                 │  AppController · StatusItem · Onboarding │
                 └──┬────────┬───────────┬────────────┬────┘
                    │        │           │            │
             HotkeyEngine AudioCapture TranscriptionEngine TextInjector
                    │        │           │            │
                    └────────┴─────┬─────┴────────────┘
                                 FabCore
                (AudioBuffer · Transcript · ModelDescriptor ·
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
Primary: a **CGEventTap** for `flagsChanged`, created as an *active* tap
(`.defaultTap`, passing events through unmodified). Active taps work with the
Accessibility permission we already require for injection; a listen-only tap
would additionally require Input Monitoring. Modifier-only chords (Right ⌥,
Fn/Globe) are distinguished by hardware key code, since flag masks don't
carry left/right. The tap re-arms itself on `tapDisabledByTimeout`. Fallback
when the tap can't be created: `NSEvent.addGlobalMonitorForEvents`, which
delivers `flagsChanged` without extra permissions. Push-to-talk and toggle
modes are interpreted by `AppController`; the monitor only reports raw
press/release transitions.

### AudioCapture
`AudioRecorder` is an actor owning an `AVAudioEngine`. The render tap
resamples on the audio thread (`TapProcessor` + `AVAudioConverter`) straight
to 16 kHz mono Float32 and accumulates under a lock — no buffers cross a
concurrency boundary. Default-device changes (AirPods mid-session) arrive as
`AVAudioEngineConfigurationChange`; the recorder re-taps with the new format
and the converter is rebuilt, keeping already-captured samples. `EnergyVAD`
(frame RMS + padding) trims silence; a Silero VAD can replace it behind the
same function later. If nothing exceeds the threshold, transcription is
skipped entirely.

### TranscriptionEngine
`TranscriptionBackend` is the seam:

```swift
protocol TranscriptionBackend: Sendable {
    func load(model: ModelDescriptor) async throws
    func transcribe(_ audio: AudioBuffer, language: Language?) async throws -> Transcript
    func unload() async
}
```

Backends: **WhisperKit** (shipped, default `base` for the slice;
`large-v3-turbo` becomes the recommended default with model management),
**Parakeet via FluidAudio** (planned; best for 8 GB M1), **Apple
SpeechAnalyzer** (planned, macOS 26+ behind availability check). Models
download on demand to `~/Library/Application Support/fabulous/models/`;
never bundled.

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
Status item + menu (AppKit), onboarding window (SwiftUI in an
`NSHostingController`) with 1 Hz permission polling — Accessibility has no
change notification API. Planned: non-activating `NSPanel` recording overlay
(all Spaces, ignores mouse, never steals focus), SwiftUI settings window,
GRDB-backed optional history.

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
| `WhisperKitBackend` | actor; non-Sendable `WhisperKit` confined (retroactive `@unchecked Sendable` to satisfy region checks) |
| `HotkeyMonitor`, `TextInjector`, UI | `@MainActor` |
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
  they don't work sandboxed. Mitigation: Developer ID + notarization +
  hardened runtime for distribution, minimal entitlements (audio-input only),
  no network beyond model downloads.
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
Planned: WAV-fixture integration test asserting expected transcript (needs
model download; will be gated for CI), overlay/latency instrumentation.
