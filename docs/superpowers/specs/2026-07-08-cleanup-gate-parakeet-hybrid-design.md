# Cleanup hallucination gate + Parakeet hybrid mode

**Date:** 2026-07-08
**Status:** Approved by Kal (section-by-section review)
**Prerequisite:** PR #8 (`parakeet-fix-ux-test-hardening`) merged first — this work builds
on its D5 short-utterance guard and terminal-delivery units.

## Problem

Two user-reported problems, investigated 2026-07-08:

1. **Wrong text inserted after dictation** (a few times, every engine). History showed the
   raw transcript was *correct* — the inserted text was wrong. Root cause: LLM cleanup
   (`FoundationModelPostProcessor`) accepts any non-empty model output wholesale. There is
   no check that the output relates to the input, so a hallucinating model (answering a
   question in the transcript, rewriting, continuing) replaces the transcript entirely.
   The prompt makes it worse: it opens with "You MUST actively transform the input … do
   not simply repeat or echo the input back" (the earlier anti-echo fix), which pushes the
   small on-device model toward rewriting. Both reported symptom grades — "completely
   unrelated text" and "mangled by cleanup" — are this one gap at different severities.
   Ruled out during diagnosis: clipboard-restore race (text was not old clipboard
   contents), stale dictation state (not a previous dictation), screen-context vocabulary
   echo (text was unrelated to on-screen content).

2. **Parakeet not good enough to be the main engine.** Kal's pains, in order: streaming
   accuracy (EOU 120M is a small model, transcripts worse than Whisper), short utterances
   dropped (FluidAudio batch throws `invalidAudioData` under 4800 samples / 0.30 s;
   PR #8's D5 guard drops them with a safety-net notice, Whisper decodes them), and
   latency/responsiveness. Goal: "main suggested engine" = Kal switches his own daily
   driver first (measured), then a "Recommended" badge in the engine picker. Default
   stays Whisper until Kal separately decides.

## Design

### Track 1 — Cleanup output gate (PR A)

New pure type in `PostProcessing`: `CleanupOutputGate`. No FoundationModels import —
fully unit-testable.

**Rule.** Legitimate cleanup only *removes* words (fillers, scratch-that), fixes
punctuation/casing, and substitutes few words (homophones, vocabulary spellings).
Hallucination *invents* words. The gate:

- Tokenizes raw and cleaned text (lowercased, punctuation stripped).
- Computes the novel-word ratio of the cleaned output — cleaned words that do not appear
  in the raw transcript. Words on the merged vocabulary list (user + screen terms) count
  as expected, not novel: vocabulary substitution is the one sanctioned source of new
  words.
- Rejects when the novel-word ratio exceeds a threshold (empirical, expected ~0.2–0.3,
  pinned by the test corpus — see Testing) **or** cleaned length exceeds ~1.5× raw length
  (the "never add content" rule made mechanical).

**On reject:** return the raw transcript and report a new `LLMCleanupOutcome.rejected`
case. It flows through the existing outcome plumbing into `DictationMetrics` and the menu
stats line, so dogfood data shows how often the model goes rogue.

**Prompt change** (`CleanupPromptBuilder`): soften the anti-echo opener to "Apply only the
rules below; if no rule applies to a part of the text, keep it word-for-word." The gate
makes echo harmless (echo = `unchanged` no-op) while hallucination now has a floor, so the
aggressive MUST-transform pressure is no longer needed.

**Invariant extension:** "cleanup may improve or no-op, never lose text" becomes
"… never lose *or invent* text." Every failure path still returns the raw transcript;
the scratch-that empty-output exception is unchanged (whole-utterance scratch passes the
gate: pure removal has zero novel words).

### Track 2 — Parakeet hybrid mode (PR B)

**Policy.** The streaming session (EOU 120M) keeps feeding overlay partials — the live
feel is unchanged. The final text always comes from a TDT v3 batch decode over the full
untrimmed buffer. Accuracy = v3 (Whisper-class); v3 decodes at ~190× real time, so the
final decode costs ~0.1–0.2 s after key release — total latency stays far under Whisper's
~2.5 s.

**Mechanism.** Extend `StreamingDictation.finalTranscript` (already the single fallback
seam, pure, tested) with a policy parameter:

- `.streamPreferred` — current behavior: use streamed text when the session survived and
  produced text, else batch. Apple Speech keeps this (its streamed final is its best
  output).
- `.batchFinal` — hybrid: run the batch decode; streamed text is the *rescue* used only
  if batch throws or returns empty. The fallback inverts, but the invariant holds in both
  directions: a transcript is never silently lost.

`AppController` selects the policy from the engine kind: Parakeet → `.batchFinal`,
Apple Speech → `.streamPreferred`. Pure decision, unit-tested.

**Metrics.** The `streamed` column keeps its meaning — "final text came from the
streaming session." Hybrid dictations record `false` (rescue path records `true`). The
pending stay-120M / hybrid / batch-only dogfood decision is resolved by this design
(hybrid); the column no longer has to arbitrate it.

**Degraded modes unchanged.** EOU models missing → session never opens → plain batch
(today's behavior). Batch model load failure → engine load fails → existing
revert-to-Whisper path.

**Session hygiene.** When the batch final wins, the streaming session is still properly
`finish()`ed/`cancel()`ed — the EOU manager resets between utterances (existing
one-session-at-a-time requirement).

### Track 2 — Short-utterance floor (PR B)

**Fix:** pad. In `ParakeetBackend.transcribe`, when samples < 4800, append trailing zeros
up to 4800 before decode. The `invalidAudioData` cliff becomes unreachable. Padding lives
in the backend, so the hybrid rescue path and the direct batch path are both covered by
one change.

**Empirical gate.** Zero-padding is a hypothesis — the model may decode padded blips as
garbage or empty. Validate with a `FAB_REAL_ASR` conditional test: `say`-synthesized short
words ("yes", "hi", ~0.2 s), assert non-empty and plausibly correct decode.

- Works → lower the D5 min-duration guard threshold to a true-noise floor (~0.05 s, below
  any word); the guard machinery stays.
- Garbage → keep D5 behavior at 0.30 s and document the limitation; blips remain Whisper's
  advantage. This outcome does not block the badge — sub-0.3 s dictations are rare and the
  safety net catches them visibly.

### Rollout

1. PR #8 merges (prerequisite).
2. **PR A — cleanup gate.** Small and urgent: bites daily, affects every engine.
3. **PR B — Parakeet hybrid + padding.** After A.
4. Kal dogfoods Parakeet as daily driver. Watch: per-engine p50/p90 in the menu,
   `rejected` cleanup rate, subjective accuracy vs Whisper.
5. Numbers hold → flip a "Recommended" badge on Parakeet in the engine picker (tiny UI
   change, its own commit, triggered by Kal). Badge ≠ default: the app default stays
   Whisper until Kal separately decides.

## Testing

- **`CleanupOutputGate` corpus:** legitimate edits that must pass — trailing scratch-that
  wiping the whole utterance, quote…unquote (adds only quote marks), vocabulary
  substitution ("whisper kit" → "WhisperKit"), homophone fixes, filler removal, new
  line/paragraph commands. Hallucinations that must be rejected — model answers a question
  from the transcript, translates, continues the text, rewrites wholesale. The threshold
  is pinned by this corpus, not chosen by feel.
- **`FinalTranscriptPolicy` matrix:** both policies × {batch ok, batch throws, batch
  empty, stream empty, no session} — the rescue matrix is exhaustive.
- **Padding:** pure unit tests on sample counts; `FAB_REAL_ASR` empirical blip test
  decides the D5 threshold outcome.
- **`PipelineTests` e2e:** fake streaming backend asserting the hybrid final comes from
  batch while partials still flow.
- **Kal's GUI smoke:** dictate a short blip and a long utterance on Parakeet; check menu
  metrics and history raw-vs-clean; confirm no cleanup rejections on normal dictations.

## Out of scope

- Changing the app-default engine (separate decision after dogfood).
- Auto-selecting engines per situation.
- LLM cleanup two-pass verification or structured generation (rejected as heavier and
  still unguaranteed; the gate is the floor).
- Prompt-only fix without the gate (rejected: no floor under a small model).
