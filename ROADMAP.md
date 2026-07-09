# Roadmap

Where fabulous is headed. Versions past v0.1.0 are intent, not promises —
this file is updated at each release, and items can move as real-world
usage data comes in. Latency and on-device privacy stay the two
non-negotiables for everything below.

## Shipped

- **v0.1.0** — Parakeet hybrid streaming (TDT v3 finals + EOU 120M live
  partials), LLM cleanup hallucination gate, screen-context vocabulary,
  security hardening (secure-input guard, model integrity manifests),
  public-release packaging. See
  [Releases](https://github.com/qkal/fabulous/releases) for the full
  history.

## v0.2 — next

- **Parakeet hybrid becomes the default engine.** Whisper remains
  installed and selectable; per-engine latency stats stay in the menu so
  the numbers, not the marketing, justify the default.
- **Homebrew cask** — `brew install --cask fabulous`, making the unsigned
  build easier to install and verify.
- **Vocabulary import/export (CSV)** — bulk-manage custom terms and
  replacements.

## v0.3

- **Language picker** — the bundled engines are already multilingual;
  this exposes language selection in Settings.
- **Terminal & coding-agent dictation** — better dictation targeting for
  terminals and AI coding tools. *Decision point: scope to be designed;
  not yet committed to a shape.*
- **Latency polish** — driven by the in-app measured metrics, as always;
  no speculative optimization.

## v1.0 — the bar

fabulous calls itself 1.0 when it is a **proven daily driver**: weeks of
continuous daily dictation, a default engine that held stable throughout,
the manual test checklist cleared, and zero transcript-loss bugs.

## 1.x — trusted install

Developer-ID signing, notarization, hardened runtime, and Sparkle
auto-update (requires an Apple Developer account), plus real screenshots
in the README.

## Later / exploring

Listed without versions — interesting, not committed:

- Per-app cleanup profiles (different formatting behavior per app)
- Voice editing commands beyond "scratch that"
- Searchable transcript history

## Out of scope

Windows/mobile ports, cloud transcription or cloud LLM options, and
meeting/file transcription — they conflict with the app's focus:
fast, fully on-device dictation on macOS.
