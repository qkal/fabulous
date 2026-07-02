# Phase 3 — Trustworthy daily driver

*Working spec, 2026-07-02. Scoped in brainstorm with kal; implement immediately after review.*

## Problem

fabulous works end-to-end but has zero real-world mileage — nobody has formed
the dictation habit yet. Three things stand in the way of daily use: rebuilds
revoke permissions (kills dogfooding), latency — the stated deal-breaker — is
invisible and unmeasured, and the app can still *surprise* the user (silent
recording starts, no way to abort, transcripts that vanish when injection
fails or focus moves).

## Goals

1. A rebuild never costs a permission re-grant (stable code signature).
2. Every dictation reports its latency; after a week of use we can decide
   streaming/Parakeet **with data**. Budget: release→inserted **< 1.5 s** for
   a 10 s utterance.
3. A transcript is never silently lost — worst case it's on the clipboard
   with a visible notice.
4. Recording state is always knowable without looking (sound cues) and
   always abortable (Esc).

## Non-Goals (parked, with reasons)

- **Parakeet backend / streaming transcription** — latency remedies chosen
  *after* instrumentation data exists, not before.
- **Paste-last-transcript hotkey** — wait for evidence the safety net isn't
  enough.
- **Notarized .dmg pipeline** — this phase is polish-inward, not
  distribution.
- **LLM post-processing** — v1.5 as planned.

## Requirements

### P0 — the phase fails without these

| # | Requirement | Acceptance criteria |
|---|---|---|
| 1 | **Stable signing.** `build.sh` auto-detects a signing identity (`CODESIGN_IDENTITY` env → first codesigning identity in Keychain → ad-hoc with warning). One-time helper script creates a local self-signed cert if the machine has none. | Rebuild + relaunch twice; Accessibility & Microphone stay granted. |
| 2 | **Latency instrumentation.** Per-stage timings (stop/VAD, transcribe, post-process, inject + total and audio length) captured per dictation, shown in the menu ("Last: 1.3 s · ASR 1.0 s") and logged. | After any dictation, the menu shows the breakdown; log line contains all stages. |
| 3 | **Keep-warm is explicit.** Model stays loaded for the app's lifetime; no idle unload in this phase (latency > memory for this user). | Documented in CLAUDE.md/architecture; no unload path is triggered by timers. |
| 4 | **Sound cues** on record start/stop (subtle system sounds), with a settings toggle, default on. | Cues audible on hold/release; toggle silences them. |
| 5 | **Esc cancels recording.** While recording, Esc discards audio (zeroed, no transcription) and is swallowed so it doesn't hit the focused app; works in PTT and toggle modes. | Hold hotkey, press Esc → idle, nothing typed, no Esc delivered to the app (event-tap path). |
| 6 | **Injection safety net.** Any injection failure/refusal → transcript goes to the clipboard *without* restore, and the overlay shows why for ~3 s. | Focus a password field, dictate → refusal message, transcript on clipboard. |
| 7 | **Focus-change guard.** Frontmost app (pid) is captured at record start; if it differs at injection time → do not inject, run the safety net with a "focus changed" notice. | Start dictating in app A, cmd-tab to B, release → nothing typed into B, clipboard + notice. |

### P1 — stretch, in order

1. **Replacement-dictionary editor** — settings tab editing pattern→replacement
   pairs (engine + tests already exist); entries persist and apply to every
   transcript.
2. **Silero VAD** — CoreML VAD behind the existing trim interface. Likely
   slips to phase 4; do not start before all P0s land.

## Success metrics

- **Leading:** p50/p90 of `total` latency over the first week of real
  dictations (target p90 < 1.5 s); zero lost transcripts.
- **Lagging:** kal still dictating daily after two weeks. If not, the next
  brainstorm asks *why* before adding features.

## Open questions (non-blocking)

- Does the self-signed cert path work fully non-interactively on this
  machine, or does Keychain prompt once? (Resolved during implementation;
  fallback is any existing dev identity.)
- Which system sounds read as "start/stop" without being annoying at 50
  dictations/day? (Pick two, revisit after use.)

## Build order

Signing → instrumentation → sound cues → Esc cancel → safety net → focus
guard → (stretch) replacements editor. Tests: metrics formatting, focus-guard
decision logic, replacement persistence round-trip.
