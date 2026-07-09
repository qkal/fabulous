# fabulous

Native macOS voice dictation, fully on-device. Hold a hotkey anywhere in
macOS, speak, release — the transcript is typed into whatever app has focus.
No cloud, no telemetry, no accounts.

[![License: GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

<!-- screenshot: menu-bar menu with latency stats -->

## Features

- **Hold-to-talk (or tap-to-toggle) dictation** anywhere, via a configurable
  global hotkey (modifier-hold like Right ⌥, or a key chord like ⌥Space).
- **Three on-device ASR engines**, switchable in Settings → General:
  - **Whisper** (default) via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
    on CoreML/ANE.
  - **Apple SpeechAnalyzer** (macOS 26+) — OS-managed, low latency.
  - **Parakeet** (TDT 0.6b v3 + streaming EOU) via
    [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Streaming partials** — see words appear in the overlay as you speak.
- **On-device LLM cleanup** (macOS 26+, Apple Foundation Models): removes
  fillers, fixes punctuation, and interprets spoken commands ("new line",
  "scratch that", "quote … unquote"). Opt-in; the raw transcript is kept.
- **Screen-context vocabulary** — reads on-screen terms (Accessibility, never
  screenshots) to bias recognition toward what you're looking at.
- **Per-app injection overrides**, a **replacements** editor, opt-in local
  **transcript history**, **Paper/Glass themes**, and per-dictation **latency
  metrics** in the menu bar.

<!-- screenshot: recording overlay pill -->

## Requirements

- **Apple Silicon** Mac (the binary is arm64-only).
- **macOS 14 (Sonoma)+** for core dictation.
- **macOS 26+** for LLM cleanup, the SpeechAnalyzer engine, and screen context.

## Install

The app is **unsigned** (there is no paid Apple Developer certificate yet), so
macOS quarantines it. Install and verify:

1. Download `fabulous-<version>.dmg` and `fabulous-<version>.dmg.sha256` from
   [Releases](https://github.com/qkal/fabulous/releases).
2. **Verify the download** (optional but recommended):

   ```sh
   shasum -a 256 -c fabulous-<version>.dmg.sha256
   ```

3. Open the dmg and drag **fabulous** into **Applications**.
4. Clear the quarantine flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

5. Launch it and grant **Microphone** and **Accessibility** when prompted.

> Because the app is unsigned, macOS revokes Microphone and Accessibility
> grants on each update — re-grant both in System Settings → Privacy &
> Security after updating. (Signed + notarized builds are planned.)

## Usage

Hold your hotkey (default **Right ⌥**), speak, release. The transcript is
inserted into the focused text field; a pill at the bottom of the screen shows
level and progress. Press **Esc** mid-recording to discard. The menu bar shows
the last latency breakdown.

A transcript is **never silently lost**: if a password field has focus, the
focused app changed mid-dictation, or insertion fails, the text goes to the
clipboard and the pill says why. (A confirmed password-field dictation goes to
a concealed clipboard that clears itself after 60 seconds.)

Everything is configurable in **Settings** (menu bar icon → Settings…):
hotkey, microphone, engine, models, replacements, per-app overrides, history,
theme.

<!-- screenshot: settings window (General) -->

## Privacy

- Audio lives in memory only and is zeroed after transcription — it is never
  written to disk.
- Transcript history is **opt-in**, stored locally in SQLite, and never leaves
  the Mac. Audio is never stored.
- Screen context is read via the Accessibility API in memory only (never
  screenshots, never persisted); password fields are skipped.
- The only network access is the explicit model download from Hugging Face.
- No sandbox: the app needs event taps and cross-app Accessibility APIs, which
  the App Store sandbox forbids. See [docs/architecture.md](docs/architecture.md).

## How it compares

fabulous is a free, open-source, fully on-device dictation tool. Unlike
cloud-backed products (Wispr Flow) or paid apps (superwhisper, MacWhisper), it
sends nothing off-device, has no account, and is GPL-licensed — at the cost of
being unsigned today and macOS-only.

## Build

Plain SwiftPM package — no project generation.

```sh
swift build --arch arm64      # compile (arm64 only)
swift test                    # unit tests (Swift Testing)
scripts/build.sh              # → build/fabulous.app
open build/fabulous.app
```

For a stable local signature that keeps permission grants across rebuilds, run
`scripts/make-dev-cert.sh` once; `build.sh` picks it up automatically. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Roadmap

See [ROADMAP.md](ROADMAP.md) for what's next (updated at each release).

## License

[GPL-3.0-or-later](LICENSE).

## Out of scope

Meeting transcription, diarization, notes/sync, cloud ASR, non-macOS ports,
App Store distribution.
