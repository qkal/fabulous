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

## Install

Requires an **Apple Silicon** Mac (arm64-only binary) running macOS 14+.

1. Download the latest `fabulous-<version>.dmg` from
   [Releases](https://github.com/qkal/fabulous/releases).
2. Open it and drag **fabulous** into **Applications**.
3. The app is unsigned (no Apple Developer certificate), so clear the
   quarantine flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

> **Updating:** each release has a fresh ad-hoc signature, so macOS
> revokes Microphone and Accessibility permissions on update — re-grant
> both in System Settings → Privacy & Security.

## Build

Requires Xcode 26+ on Apple Silicon. No project generation step — this is a
plain SwiftPM package.

```sh
scripts/build.sh        # → build/fabulous.app (release, ad-hoc signed)
swift test              # unit tests
open build/fabulous.app
```

For a stable signature (keeps permission grants across rebuilds), run once:

```sh
scripts/make-dev-cert.sh   # creates a local "fabulous-dev" signing identity
```

`build.sh` picks it up automatically from then on. To use a real Apple
identity instead, set `CODESIGN_IDENTITY` explicitly.

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
recording level and transcription progress. Subtle sound cues mark start and
stop; press **Esc** mid-recording to discard. After each dictation the menu
bar shows the latency breakdown ("Last: 1.3 s · ASR 1.0 s").

A transcript is never silently lost: if a password field has focus, the
focused app changed mid-dictation, or insertion fails, the text lands on the
clipboard and the pill tells you why.

Everything is configurable in Settings (menu bar icon → Settings…):

- **Hotkey** — record any modifier-hold (e.g. Fn) or key chord (e.g. ⌥Space),
  in hold-to-talk or tap-to-toggle mode.
- **Microphone** — pick a specific input or follow the system default.
- **Models** — download, switch, or delete models.
- **Replacements** — whole-word fixes for names the model keeps mishearing
  ("anthropite" → "Anthropite").
- **History** — the last 500 transcripts, stored only on this Mac (SQLite),
  with a toggle to disable and a Clear History button. Audio is never stored.

## Privacy

- Audio lives in memory only and is zeroed after transcription.
- The only network access is the explicit model download from Hugging Face.
- No sandbox in v1 — the app needs event taps and cross-app Accessibility
  APIs, which don't fit the App Store sandbox. Distribution is unsigned
  (ad-hoc signed only, no Apple Developer certificate). Tradeoff documented in
  [docs/architecture.md](docs/architecture.md).

## Out of scope (v1)

Meeting transcription, diarization, notes/sync, cloud ASR, non-macOS ports,
App Store distribution.
