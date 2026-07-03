# LLM Post-Processing (Apple Foundation Models)

Status: implemented 2026-07-03 (this plan: docs/superpowers/plans/2026-07-03-llm-post-processing.md).

## Goal

Optional on-device LLM pass that cleans dictated text before injection:
remove filler words, fix punctuation/capitalization and obvious ASR errors,
interpret a small set of spoken commands, and bias spellings toward a
user-maintained vocabulary. Off by default; opt-in via Settings.

Non-goals (v1): rewrite/tone modes, screen-content context (screenshot or
AX focused-field text — deferred to v2), cloud or third-party models,
folding the replacement dictionary into the prompt.

## Engine

Apple Foundation Models framework (macOS 26, on-device ~3B model).
Rationale: private and offline like the rest of the app, no model download
to manage, no API key, and the cleanup task is easy enough for a small
model. The `TextPostProcessor` protocol keeps the door open for other
providers later.

Constraints accepted: requires Apple Intelligence enabled; text-only input;
modest quality ceiling.

## Architecture

New SwiftPM target `PostProcessing` (Sources/PostProcessing/), depends on
FabCore only. It is the only target importing FoundationModels (same
pattern as TranscriptionEngine/WhisperKit and HistoryStore/GRDB).

Components:

- `FoundationModelPostProcessor` (actor, conforms to
  `FabCore.TextPostProcessor`): holds a prewarmed `LanguageModelSession`;
  `process(_:)` issues one guided-generation request returning
  `@Generable struct CleanupResult { var cleanedText: String }`.
- `CleanupPromptBuilder` (pure struct): `(text, vocabulary, appName) →
  prompt`. Assembles base cleanup rules, command semantics, vocabulary
  list, and app hint. Pure so tests pin exact prompt without the model.
- `PostProcessingAvailability` (enum): wraps
  `SystemLanguageModel.default.availability` into
  available / appleIntelligenceOff / modelNotReady / unsupported, for the
  settings UI.
- `LanguageModelRequesting` (protocol): thin seam over the session so
  fallback behavior is testable with a fake.

Wiring (FabulousApp): `AppController` builds the pipeline
`[llmStage?, replacementStage?]` — LLM first when the toggle is on and the
model is available, `ReplacementDictionary` after, so deterministic user
rules always win. The app hint is resolved from `recordingTargetPID` (the
app focused at recording start — the injection target, same source the
focus guard trusts), not the frontmost app at `finishRecording`.
Vocabulary comes from `SettingsStore`.

Flow: transcript → LLM cleanup (or passthrough) → replacements →
injection. Streaming is unaffected: overlay partials stay raw; only the
final transcript passes the pipeline. The existing `postMs` metric
captures the added latency; no metrics schema change.

## Model behavior

Prompt contract:

- Remove fillers (um, uh, you know, like-as-filler); conservative — keep
  "like" when comparative.
- Fix punctuation, capitalization, obvious ASR homophone errors.
- Spoken commands, only when spoken as commands (not content — "new line
  of credit" stays):
  - "new line" → `\n`
  - "new paragraph" → `\n\n`
  - "scratch that" → delete the preceding clause/sentence
  - "quote … unquote" → wrap the span in quotes
- Prefer vocabulary spellings when audio is ambiguous.
- One-line app hint ("text destined for app: Xcode").
- Never add content, never answer questions found in the transcript,
  never translate. Output only the cleaned text (guided generation
  enforces the shape).

Session: temperature 0.2. A fresh `LanguageModelSession` is created per
dictation (sessions accumulate context; reuse would grow the prompt and
leak text across dictations). `prewarm()` is called when the toggle is
enabled and at app start when already on (keep-warm philosophy) — the
model stays resident; per-session setup is cheap.

## Settings UI

General tab, "Clean up with Apple Intelligence" section:

- Toggle, off by default. When the model is unavailable the toggle is
  disabled with a reason: "Requires Apple Intelligence enabled in System
  Settings" / "Model downloading…" / "Not supported on this Mac".
- Vocabulary editor: small add/remove string list (same pattern as the
  Replacements tab), stored in `SettingsStore` (UserDefaults, [String]).
  Feeds only the LLM prompt.

## Failure handling

Invariant: the LLM stage can improve or no-op, never lose text.

- Any throw, guided-generation refusal, or guardrail trip → return raw
  text; log the reason.
- Timeout 3 s → raw text. `postMs` records the real cost either way.
- Empty/whitespace output for non-empty input → raw text, with one
  exception: when the raw text contains a command phrase ("scratch
  that"), an empty result is legitimate ("blah blah scratch that" cleans
  to nothing) and is accepted — nothing is injected, overlay hides.
  Without a command phrase present, empty output is treated as model
  failure.
- Model becomes unavailable mid-session → stage self-disables silently;
  settings shows the unavailable state next time it opens.
- Safety net untouched: cleanup happens before the injection decision;
  the clipboard fallback receives the same text injection would have.

Accepted limitations (v1): the overlay keeps the "Transcribing…" state
through the LLM pass (no separate "Cleaning…" state); Esc cannot cancel
the LLM pass (the 3 s timeout bounds it); the vocabulary list is not fed
to the Whisper prompt.

## Injector: newline support

"new paragraph"/"new line" produce the first multiline transcripts, and
the injector was never exercised with `\n`:

- Keystroke strategy: `keyboardSetUnicodeString` does not reliably
  produce Return in target apps. Split text on `\n` and post a real
  Return key event (keycode 36) between segments.
- axInsert and paste handle `\n` natively; single-line AX fields ignore
  it (acceptable — same behavior as pasting multiline into them).
- Injector unit tests cover the split logic (pure segmentation function).

## History: raw transcript preservation

`TranscriptEntry` gains a nullable `rawText` column (GRDB migration).
Set only when the LLM stage actually changed the text; NULL otherwise.
History detail view shows the original beneath the cleaned text when
present. Keeps the "never lose text" invariant even when cleanup
mangles a transcript. Cap-pruning and Clear History treat the column as
part of the row (no separate lifecycle).

## Testing

Always run:

- `CleanupPromptBuilder`: prompt contains vocabulary, app name, command
  rules; snapshot exact assembly.
- `FoundationModelPostProcessor` with a fake `LanguageModelRequesting`:
  throw → raw, timeout → raw, empty output → raw.
- Pipeline order: fake LLM stage + real `ReplacementDictionary`;
  replacements apply to LLM output.
- Empty-output guard: empty result + command phrase in raw → accepted;
  empty result without command phrase → raw text returned.
- Injector newline segmentation: `\n` splits produce Return keystrokes
  between text segments.
- History: entry stores `rawText` only when LLM changed the text.

Conditional (`FAB_REAL_LLM=1`, pattern matches `FAB_REAL_ASR`; skip when
the model is unavailable): filler removal, "new paragraph",
"scratch that", vocabulary bias, and the "new line of credit" negative
case against the real model.

## Decisions log

- Job scope: cleanup + small command set + context-aware fixes; rewrite
  modes rejected (2026-07-03).
- Engine: Apple Foundation Models over cloud/Ollama — privacy, offline,
  zero setup.
- Gate: settings toggle, always-on when enabled; no length threshold or
  per-dictation modifier in v1.
- Context sources: custom vocabulary + frontmost app name. Screen context
  deferred to v2; if built, prefer AX focused-field text (permission
  already held) over screenshot+OCR (new Screen Recording permission).
- Approach: single LLM stage with guided generation (A), over
  deterministic command pre-pass (B — "new line" false positives worse
  than occasional LLM misses) and LLM-does-replacements (C — destroys
  determinism).
- Gap review (2026-07-03): keystroke injector needs explicit Return
  events for `\n`; empty-output guard gets a command-phrase exception so
  "scratch that" can legitimately empty an utterance; app hint sourced
  from `recordingTargetPID`, not frontmost-at-finish; fresh FM session
  per dictation; history preserves raw text in nullable `rawText`
  column when cleanup changed it.
