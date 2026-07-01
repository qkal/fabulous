# fabulous

Native macOS voice dictation. Hold a hotkey anywhere in macOS, speak, release —
the transcription is typed into whatever app has focus.

One tool, one job: dictation that feels instant and never sends audio
off-device. No cloud, no telemetry, no accounts.

- **Native Swift 6** (strict concurrency), SwiftUI + AppKit. No Electron, no Tauri.
- **On-device ASR** via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper on CoreML/ANE); Parakeet and Apple `SpeechAnalyzer` backends planned.
- **Apple Silicon only**, macOS 14 (Sonoma) or newer.

## Status

Early but usable: hold **Right ⌥** (configurable) → record → Whisper on
CoreML → text lands in the frontmost app. Includes a settings window
(hotkey recorder, microphone picker, launch-at-login), model management
(large-v3-turbo / small / base with download progress), a floating recording
overlay, and optional local transcript history. See
[docs/architecture.md](docs/architecture.md) for where this is going.

## Build

Requires Xcode 16+ on Apple Silicon. No project generation step — this is a
plain SwiftPM package.

```sh
scripts/build.sh        # → build/fabulous.app (release, ad-hoc signed)
swift test              # unit tests
open build/fabulous.app
```

For a stable signature (keeps permission grants across rebuilds):

```sh
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build.sh
```

## First run

fabulous walks you through two permissions:

1. **Microphone** — records only while the hotkey is held.
2. **Accessibility** — needed for the global hotkey (event tap), for inserting
   text via the Accessibility API, and for synthesizing ⌘V.

With ad-hoc dev signing, macOS invalidates these grants on every rebuild —
re-toggle fabulous in System Settings → Privacy & Security → Accessibility,
or build with `CODESIGN_IDENTITY`.

On first launch fabulous downloads the recommended model
(Whisper large-v3-turbo, ~1.6 GB — grab a coffee; the menu bar shows
progress) into `~/Library/Application Support/fabulous/models/`. Prefer a
smaller download? Open Settings → Models and install `base` (~150 MB) or
`small` instead. Models are never bundled with the app.

## Usage

Hold **Right ⌥ (Option)**, speak, release. The transcript is inserted into
the focused text field, and a small pill at the bottom of the screen shows
recording level and transcription progress. If a password field has focus,
fabulous refuses to type.

Everything is configurable in Settings (menu bar icon → Settings…):

- **Hotkey** — record any modifier-hold (e.g. Fn) or key chord (e.g. ⌥Space),
  in hold-to-talk or tap-to-toggle mode.
- **Microphone** — pick a specific input or follow the system default.
- **Models** — download, switch, or delete models.
- **History** — the last 500 transcripts, stored only on this Mac (SQLite),
  with a toggle to disable and a Clear History button. Audio is never stored.

## Privacy

- Audio lives in memory only and is zeroed after transcription.
- The only network access is the explicit model download from Hugging Face.
- No sandbox in v1 — the app needs event taps and cross-app Accessibility
  APIs, which don't fit the App Store sandbox. Distribution is Developer ID
  signed + notarized outside the App Store. Tradeoff documented in
  [docs/architecture.md](docs/architecture.md).

## Out of scope (v1)

Meeting transcription, diarization, notes/sync, cloud ASR, non-macOS ports,
App Store distribution.
