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

Early. The vertical slice works: menu bar icon → hold **Right ⌥** → record →
Whisper `base` → text lands in the frontmost app. See
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

The Whisper `base` model (~150 MB) downloads on first launch into
`~/Library/Application Support/fabulous/models/`. Models are never bundled
with the app.

## Usage

Hold **Right ⌥ (Option)**, speak, release. The transcript is inserted into the
focused text field. If a password field has focus, fabulous refuses to type.
The menu bar icon shows state: ready / recording / transcribing.

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
