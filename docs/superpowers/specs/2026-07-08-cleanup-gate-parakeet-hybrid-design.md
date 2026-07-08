# Cleanup hallucination gate + Parakeet hybrid mode

**Date:** 2026-07-08
**Status:** Approved by Kal (section-by-section review); gap-hunt pass applied 2026-07-08
**Prerequisite:** PR B only: PR #8 (`parakeet-fix-ux-test-hardening`) merged first — the
hybrid work builds on its D5 short-utterance guard and terminal-delivery units. PR A
(cleanup gate) touches only `PostProcessing`, the FabCore outcome enum, and stats
plumbing — it is independent of PR #8 and ships immediately.

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
  words. **Vocabulary credit is capped** (≤ max(2, ~10% of cleaned tokens); beyond that,
  vocabulary words count as novel) — otherwise a hallucination composed of screen terms
  would pass the gate, which is precisely the vocabulary-echo failure mode.
- Rejects when the novel-word ratio exceeds a threshold (empirical, expected ~0.2–0.3,
  pinned by the test corpus — see Testing) **or** the cleaned token count exceeds
  `rawTokens × 1.5 + 3` (the "never add content" rule made mechanical; the absolute
  slack keeps tiny utterances like "hi" → "Hi." from tripping a bare ratio).

**Accepted limitation:** tokenization is whitespace-based. Non-spaced scripts (CJK)
degrade to always-reject, i.e. cleanup permanently no-ops there — safe (raw text is
delivered) and acceptable for now.

**On reject:** return the raw transcript and report a new `LLMCleanupOutcome.rejected`
case. Outcomes persist by raw string (no schema migration needed); the HistoryStore
cleanup-stats aggregate gains a `rejectedCount` alongside `fellBackCount`, and the menu
cleanup line shows it — dogfood data shows how often the model goes rogue. History's
`rawText` logic needs no change: a rejected dictation inserts the raw text, so no raw
copy is stored (same as `fellBack`).

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

**Ordering (latency-critical):** under `.batchFinal` the batch decode runs *first*, without
waiting for the streaming session to finalize. On batch success the session is
`cancel()`ed (its EOU finalize wait is never paid for text we discard); only on batch
failure/empty does the rescue path call `session.finish()` and use its text.

**No VAD re-trim on the hybrid primary path:** the current fallback closure runs a Silero
trim before batch — acceptable when fallback was rare, but hybrid would pay that latency
every dictation, re-adding exactly the stop-trim cost the streaming path removed. The
`.batchFinal` primary decode takes the untrimmed buffer as-is: v3 tolerates leading/
trailing silence and decodes at ~190× real time, so the skipped trim costs more than the
extra decoded silence. The `.streamPreferred` rescue closure keeps its lazy trim
(unchanged behavior).

`AppController` selects the policy from the engine kind: Parakeet → `.batchFinal`,
Apple Speech → `.streamPreferred`. Pure decision, unit-tested.

**Metrics.** The `streamed` column keeps its meaning — "final text came from the
streaming session." Hybrid dictations record `false` (rescue path records `true`). The
pending stay-120M / hybrid / batch-only dogfood decision is resolved by this design
(hybrid); the column no longer has to arbitrate it.

**Degraded modes unchanged.** EOU models missing → session never opens → plain batch
(today's behavior). Batch model load failure → engine load fails → existing
revert-to-Whisper path.

**Session hygiene.** Every path ends the session exactly once — `cancel()` when batch
wins, `finish()` on the rescue path — so the EOU manager resets between utterances
(existing one-session-at-a-time requirement).

**Accepted UX note:** overlay partials come from the 120M model while the inserted final
comes from v3, so the pill text and the final text can differ visibly on *every*
dictation, not just the rare-fallback case today. Accepted: partials are a preview;
final accuracy is the goal.

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

1. **PR A — cleanup gate.** Small and urgent: bites daily, affects every engine.
   Independent of PR #8 — ships first, no waiting.
2. PR #8 merges (prerequisite for PR B only).
3. **PR B — Parakeet hybrid + padding.** After PR #8.
4. Kal dogfoods Parakeet as daily driver. Watch: per-engine p50/p90 in the menu,
   `rejected` cleanup rate, subjective accuracy vs Whisper.
5. Numbers hold → flip a "Recommended" badge on Parakeet in the engine picker (tiny UI
   change, its own commit, triggered by Kal). Badge ≠ default: the app default stays
   Whisper until Kal separately decides.

## Testing

- **`CleanupOutputGate` corpus:** legitimate edits that must pass — trailing scratch-that
  wiping the whole utterance, quote…unquote (adds only quote marks), vocabulary
  substitution ("whisper kit" → "WhisperKit"), homophone fixes, filler removal, new
  line/paragraph commands, number normalization ("twenty three" → "23" — the model does
  this unprompted; the corpus decides whether the threshold tolerates it or it lands on
  the reject side as a no-op). Hallucinations that must be rejected — model answers a
  question from the transcript, translates, continues the text, rewrites wholesale,
  output built from vocabulary/screen terms (must exceed the vocab-credit cap). The
  threshold is pinned by this corpus, not chosen by feel.
- **`FinalTranscriptPolicy` matrix:** both policies × {batch ok, batch throws, batch
  empty, stream empty, no session} — the rescue matrix is exhaustive, including
  session end-of-life assertions (cancelled on batch success, finished on rescue).
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
