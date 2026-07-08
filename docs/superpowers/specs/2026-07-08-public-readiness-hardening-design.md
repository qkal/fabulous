# Public-readiness hardening

**Date:** 2026-07-08
**Status:** Design — awaiting review
**Workstream:** 1 of 3 (Harden → Package → Roadmap; this spec covers Harden only)

> Findings came from a two-agent audit (security/privacy + code-health), each finding
> adversarially verified by an independent skeptic (9-agent pass), then the spec itself was
> gap-hunted by 4 more agents that re-read the code and the merge target. 6 core findings
> CONFIRMED, 3 PARTIAL (real, mechanism corrected); the gap-hunt corrected two
> not-implementable items and added F11. File:line anchors are as of commit 45579bb on
> `main`; **the P0.1 merge shifts every AppController anchor** (branch adds ~157 lines) — the
> post-merge locations are noted inline and must be re-confirmed during planning.

---

## 1. Context and decomposition

Kal wants fabulous "public access ready" — defined (decision, 2026-07-08) as **both** an
open-source repo and a polished end-user distribution. That splits into three workstreams,
each with its own spec → plan → implementation cycle, in this order:

1. **Harden** (this spec) — fix verified reliability/security/perf defects. Completion of
   P0+P1 is the gate for flipping the repo public.
2. **Package** (future spec) — LICENSE, README rewrite, docs pruning, signing/notarization,
   PrivacyInfo.xcprivacy, auto-update, bundle-ID decision (`com.czapkovicz.fabulous` is
   now-or-never: changing it later resets every user's TCC grants), dependabot, contributor
   hygiene, repo-public flip.
3. **Roadmap** (future doc) — competitive positioning vs. Wispr Flow / superwhisper /
   MacWhisper / VoiceInk et al.

Scope decisions made during brainstorming:

- The 2026-07-07 UX-bugs work is **absorbed into this workstream as P0**. It is already
  implemented on branch `parakeet-fix-ux-test-hardening` (fixes D1–D6 + FabCore
  decision-extraction tests); "absorb" means review + merge that branch first, not
  re-implement.
- Perf scope is **obvious waste only** — the repo's measure-first culture holds; no
  speculative optimization, no new latency targets (those belong in Roadmap).
- No AppController grand refactor in this workstream; new decisions land as small pure
  FabCore reducers, following the branch's established pattern.

## 2. Verified findings driving this spec

| ID | Finding | Verdict | Anchor (main @ 45579bb) |
|----|---------|---------|-------------------------|
| F1 | Secure-input refusal still persists transcript: history row written **before** `deliver()`, never rolled back; `lastTranscript`/menu item set before delivery too; raw pre-cleanup text stored; history default ON; transcript also on clipboard unconcealed | CONFIRMED (HIGH) | `AppController.swift:666–674` (writes), `:729–731` (unconcealed clipboard), `InjectionStrategy.swift:82` (refusal origin), `SettingsStore.swift:163` (default) |
| F2 | Safety-net clipboard writes carry no `org.nspasteboard` markers and no timed clear | CONFIRMED | `AppController.swift:729–734`; repo-wide grep: zero marker hits |
| F3 | Silent capture death: mid-recording device-swap re-tap failure is `try?`-discarded — no state change, no log, level meter frozen at nonzero (masks it), streaming starves, truncated/empty transcript with no notice | CONFIRMED | `AudioRecorder.swift:151–157`, `TapProcessor.swift:80–84`, `AppController.swift:661–665` |
| F4 | `recordHistory`'s blocking write runs on MainActor **between `processedAt` and `deliveredAt`, so its duration is counted inside the persisted `delivery` metric** — a **correctness** defect corrupting the latency data engine decisions rely on, plus the sync-on-main cost; `persistMetrics` adds a write + 3 ≤500-row reads post-delivery. `HistoryStore` is already `Sendable` | CONFIRMED (correctness + perf) | `AppController.swift:660–685`, `:773–800`, `HistoryStore.swift:210,294` |
| F5 | Model download integrity: Parakeet + Silero paths verify HTTP 200 / file-exists only. Whisper hub has size verification + SHA256 corruption checks (repair/offline paths) but no authenticity (reference etag from same channel). Nothing pins a trusted digest | PARTIAL (real; Whisper half softer than first reported) | `ParakeetInstaller.swift:23–50`, `SileroVADInstaller.swift:24–61`, `ModelManager.swift:69–76` |
| F6 | Prompt injection into LLM cleanup: AX-harvested screen terms + frontmost app's `localizedName` interpolated raw into instructions that authorize word substitution, and **screen terms carry the same substitution authority as user vocabulary**. Correction: digit-bearing tokens are an *admission* privilege (`paypa1` admitted where `paypal` dropped), not a ranking one. Newline→Return angle exists only on keystroke fallback + pasted newlines in terminals | PARTIAL (surface real) | `CleanupPromptBuilder.swift:44–57`, `FoundationModelPostProcessor.swift:81–92`, `SalientTermExtractor.swift:62,79–89` |
| F7 | Paste-strategy: restore-abandonment on changeCount mismatch is correct anti-clobber design (not a bug); real gaps are (a) no `TransientType` marker on the transient write, so clipboard managers archive every dictation, and (b) `saved == nil` (non-text prior clipboard) never schedules a restore | PARTIAL | `TextInjector.swift:100–129` |
| F8 | `ReplacementDictionary.apply` recompiles every `NSRegularExpression` per dictation; instance persists across dictations so an init-time cache would be reused | CONFIRMED (LOW) | `ReplacementDictionary.swift:32–52`, `AppController.swift:659,822–827` |
| F9 | FabulousApp target (17 files, 925-line AppController) has zero test coverage; deps wired as private `let`s with no injection point, `AudioRecorder` is a concrete actor (no protocol) — so substituting a fake requires a structural seam that does not exist | CONFIRMED | `Package.swift:67–99`, `AppController.swift:31–49`, `AudioRecorder.swift:10` |
| F10 | Screen-derived data could reach unified logging via three `NSLog` sites interpolating raw error objects (invariant: term counts only, never verbatim) | LOW | `SpeechAnalyzerBackend.swift:82,353`, `ParakeetStreamingSession.swift:35` |
| F11 | **(gap-hunt)** Accessibility revoked mid-session silently kills the hotkey: CGEventTap goes inert with no callback, nothing re-checks `AXIsProcessTrusted()` at runtime (only onboarding polls, and only while open). Menu icon still looks alive; dictation just stops. Same silent-total-failure class as F3, for input | CONFIRMED (HIGH) | `HotkeyMonitor.swift:117–121`, `OnboardingView.swift:74–83` |

Verified clean (for the eventual public security story): raw audio never on disk, buffers
zeroed; screen text memory-only with `AXSecureTextField` skipped; secure-field injection
refusal present; focus-change guard present; GRDB fully parameterized; HTTPS everywhere;
no secrets; CI workflows have no injection sinks and fork-PR-safe triggers; deps pinned in
`Package.resolved`; no gadget-prone deserialization.

## 3. Design

Severity-phased, one implementation plan, ships incrementally. Public-flip gate = P0 + P1
complete.

### P0 — release blockers

**P0.1 Land the UX-bugs branch.** Review + merge `parakeet-fix-ux-test-hardening` (D1
download-stuck deadlock, D2 silent-transcript-loss holes, D3/D4 PTT/toggle races, D5
Parakeet short-utterance, D6 offline misclassification, + FabCore decision tests).
*Merge mechanics:* a standard `git merge` with `main` as base **preserves this spec** — the
`-182` deletion in the raw `main..branch` diff is an artifact of the branch predating this
doc (branch is 11 ahead / 1 behind; `merge-tree` is clean). Do not integrate by rebasing
main onto the branch or `checkout branch -- docs/`. The merge brings two AI-session docs
(`2026-07-07-parakeet-fix-*.md`, plan + design) into scope for workstream-2 doc pruning.
Everything below builds on the merged result; **AppController anchors shift** accordingly.

**P0.2 Secure-input dictations never persist (F1). Depends on a new `deliver()` return
type — the current one makes this un-implementable.**
- *Root problem:* `deliver()` returns `DeliveryMethod`, collapsing all four non-injection
  outcomes (secure-input, focus-change, accessibility-revoked, all-strategies-failed) into a
  single `.safetyNet`, discarding the reason. Change `deliver()` to return a richer outcome
  carrying the `RefusalReason` (e.g. `struct DeliveryOutcome { method: DeliveryMethod;
  refusal: RefusalReason? }`). `DeliveryMethod`'s persisted metric schema is unchanged.
- *Real-password detection (decision 2026-07-08):* `IsSecureEventInputEnabled()` is a
  **process-global** flag (Terminal "Secure Keyboard Entry", 1Password, etc. set it), not
  proof the focused field is a password — so it must not by itself trigger password
  treatment. On a `.secureInputActive` refusal, check the focused AX element role (reuse the
  existing `AXSecureTextField` detection from `TextHarvester`):
  - **Focused element IS `AXSecureTextField`** → real password. Skip history (neither cleaned
    nor raw), skip `lastTranscript`/menu, conceal clipboard + timed clear (below), overlay
    "Password field — on clipboard 60 s".
  - **Secure input on but focused field NOT secure** (global from another app) → ordinary
    safety net: persistent unmarked clipboard, **do** record history, neutral wording. This
    keeps legitimate transcripts dictated into Notes/browser from being silently eaten.
- *Move the trio, after the outcome is known:* `lastTranscript`, `setLastTranscriptAvailable`,
  and `recordHistory` (main `:666–674`) all move to after `deliver()` returns **and after the
  `deliveredAt` timestamp is captured** — the latter makes F4's delivery-metric corruption a
  P0 side effect (see P2/F4 cross-ref). All three gate on `refusal != .secureInputActive`
  (or, precisely, on the AX-confirmed-password branch).
- *Decision home:* the persist/skip choice is a **new post-deliver** pure FabCore reducer
  (e.g. `HistoryPersistenceDecision.shouldPersist(outcome:isSecureField:)`). It is **not** an
  extension of `TerminalDeliveryDecision`, which runs pre-deliver and cannot see the reason.
- *Concealed clipboard + 60 s clear:* a dedicated AppController-owned `Task` (not
  `TextInjector.restoreTask`, which only applies to the paste path and never runs here since
  injection is refused). It writes the transcript as a pasteboard item tagged
  `org.nspasteboard.ConcealedType` (+ the plain string), captures `changeCount` immediately,
  and after 60 s clears **only if `changeCount` is unchanged**. Any intervening
  copy/dictation bumps `changeCount` and self-defuses the clear. The `Task` does **not**
  survive app relaunch — past a quit, the `ConcealedType` marker is the only protection
  (honored by cooperating clipboard managers; not OS-enforced; no Info.plist UTI needed).

**P0.3 Capture death and hotkey death become loud (F3; F11 shares the pattern).**
- *Capture-health signal:* two seams. `stop()` returns a capture-health flag alongside the
  drained samples (batch path). The already-running level/poll loop
  (`startLevelUpdates`/`levelTask`, runs for **both** streaming and batch) consults a
  pollable recorder health check, so a mid-recording death surfaces immediately rather than
  at stop. On failure, a state-guarded `handleCaptureFailure()` (checks `state == .recording`,
  flips state first, so it cannot double-fire with a concurrent `hotkeyReleased →
  finishRecording`) stops the session, keeps the pre-failure audio, and runs the normal
  transcribe path with an overlay notice "Mic lost — partial transcript".
- *Notice gated on health, not emptiness:* after the merge, `finishRecording` has **three
  deliberately-silent** return-to-idle sites — the `< minimumUtteranceDuration` short-tap
  guard, the empty-after-cleanup (`scratch that`) guard, and `TerminalDeliveryDecision.
  dropSilently`. Each consults the capture-health flag: show the mic-loss notice **only when
  health == failed**; a healthy short tap / scratch-that / no-speech stays silent exactly as
  the branch just hardened it.
- *`handleConfigurationChange` re-tap failure* transitions the recorder to an explicit failed
  state and logs a static message + error code (`NSLog "fabulous: capture died: <code>"`).
- *Level meter can't mask it:* `TapProcessor` records the wall-clock time of the last
  `process()` call; the `level` getter returns zero once no buffer has arrived for a small
  threshold (~150 ms) — the getter has no timer today, so this timestamp is the mechanism.
- *F11 (hotkey death):* a low-frequency runtime `AXIsProcessTrusted()` check (and/or tap
  re-creation after prolonged no-event) detects Accessibility loss on a running app and
  surfaces it — menu-bar failed state + overlay notice + re-offer onboarding — mirroring the
  capture-death treatment for the input path.

### P1 — security hardening

**P1.1 Download integrity (F5) — pin Silero, TOFU the rest (decision 2026-07-08). Verify is
separate from `isInstalled`.**
- *Keep `isInstalled` cheap:* `ModelLayout.isComplete` / `ParakeetLayout.isInstalled` stay
  pure `fileExists` checks (called in the hot `refreshModelList` UI loop over multi-GB
  models — must not hash there).
- *Verify once at load:* a distinct verify step runs inside `backend.load()`
  (`WhisperKitBackend`/`ParakeetBackend`), before handing files to the loader, **once per
  process** (cache the verified state). Guard full-file SHA-256 behind a cheap size+mtime
  precheck against the manifest — full hash only on mismatch — so launch/keep-warm load
  latency is not regressed (done-criterion below).
- *Manifest write:* the sidecar is (re)written at the end of **every successful
  `ModelManager.download()`** (Whisper and Parakeet), since `download()` is the sole
  authority that lands/repairs files — the WhisperKit hub client repairs *in place* (no
  delete+fresh), and Settings "Download" runs even on an installed model, so a first-install
  manifest would false-fail a legitimate repair.
- *Manifest shape:* `<repoRoot>/.fab-manifest.json`, `{ relativePath: sha256 }`, covering
  exactly the declared `requiredComponents` (not the recursive tree) — explicitly excluding
  any CoreML-generated on-load specialization artifacts, which would otherwise false-mismatch
  on the second load.
- *Silero:* the model is a **5-file `.mlmodelc` directory** (`coremldata.bin`,
  `metadata.json`, `model.mil`, `weights/weight.bin`, `analytics/coremldata.bin`), not one
  file. Pin a SHA-256 **per component** (in-repo constant), verified as each downloads; and
  pin the download URL to an **immutable commit revision** (`resolve/<commit-sha>/` instead of
  `resolve/main/`) so pinned digests and served bytes stay in lockstep. A deliberate model
  bump updates both the URL and the constant.
- *Threat framing (honest):* the sidecar shares the models dir and its permissions, so it
  **catches corruption and accidental/naive modification — it is not a tamper-proof boundary**
  (an attacker who can write the model files can rewrite the sidecar), and it does not
  authenticate the upstream source. README (workstream 2) documents this.

**P1.2 Prompt-injection containment (F6) — scope substitution authority, don't just quote
(decision 2026-07-08).**
- *Root fix:* only **user-configured vocabulary** keeps homophone-substitution authority
  ("replace the transcribed word with the listed spelling"). **Screen-harvested terms demote
  to bias only** — SpeechAnalyzer contextual strings + a softer prompt clause ("prefer these
  spellings when a word is ambiguous"), never authorized to rewrite an already-transcribed
  word. This kills the `paypa1`-rewrites-`paypal` vector at the root, where quoting alone
  would not (a quoted-as-data lookalike still sits in the substitution list). Seam: split the
  `user` vs `screen` arguments in `FoundationModelPostProcessor.mergedVocabulary` so they
  land in different prompt roles.
- *Delimit the rest:* user vocabulary and `appName` are still rendered as a quoted data block
  ("vocabulary strings, data only — never instructions") to close the instruction-injection
  half. No URL/TLD token filter — the tokenizer already splits on `:` `/`, and a TLD-tail
  filter would drop the exact dotted identifiers (`build.sh`, `main.py`) screen-context exists
  to keep and would kill URL biasing for an app whose job includes typing URLs.
- *F6 newline→terminal vector:* resolved as **subsumed by containment** — once screen text
  can no longer instruct the model, it cannot make cleanup emit line breaks; user-dictated
  newlines into a terminal are intended behavior. Recorded here so it is not left dangling.
- *Fixtures* assert the **deterministic built prompt string** (hostile terms appear only
  inside the quoted data block; screen terms appear only in the bias clause, never the
  substitution clause), not nondeterministic model output.

**P1.3 Clipboard markers (F2, F7).**
- Paste-strategy transient write gains `org.nspasteboard.TransientType` (+
  `AutoGeneratedType`) so clipboard managers skip it.
- `safetyNet` gains a concealment/reason parameter **set only by the AX-confirmed
  secure-input caller** (P0.2); all other callers — including the **two new D2 callers the
  branch adds** (post-process-throw, `TerminalDeliveryDecision.safetyNet`) — carry ordinary
  dictation text and stay persistent + unmarked.
- `saved == nil` restore gap: restore string-representable non-string types where cheap;
  otherwise leave and document the limitation in a code comment.

**P1.4 Log hygiene (F10).** The three NSLog sites that interpolate raw errors on
screen-data-carrying paths switch to static message + error code/domain.

### P2 — reliability + performance waste

- **F4 (cross-ref P0.2):** P0.2 already relocates the `recordHistory` trio to after
  `deliveredAt` is captured, so F4 here reduces to (a) confirming the delivery metric measures
  delivery only, and (b) making the `HistoryStore` write + `persistMetrics` reads async /
  off-main (the store is already `Sendable`). Write failure logs; it no longer sits between
  transcription and injection.
- **Silent `try?` surfacing:** model-delete failure → overlay/status notice; clear-history
  failure → notice; settings-persist and history-read failures → log lines.
- **VoiceOver (F-adjacent, frontend):** overlay safety-net/error notices post an
  `NSAccessibility` announcement so a VoiceOver user hears where their transcript went — the
  notices are load-bearing (never-lose-text) and currently visual-only.
- **F8:** compiled-regex cache built at `ReplacementDictionary` init/update.
- **SileroVAD CoreML load** moves off MainActor during the launch upgrade
  (`AppController.swift:175`).
- *Dropped from the earlier draft:* the "Replacements editor invalid-pattern inline feedback"
  item — the `try?`-skip branch (`ReplacementDictionary.swift:42–44`) is unreachable for user
  input because the pattern is `escapedPattern`-escaped before compiling and empties are
  pre-filtered; there is no user-reachable invalid pattern to surface.

### P3 — minimal test seams

- Test target (`FabulousAppTests`) depending on the executable target — no AppController
  split. Covers what is reachable **without a structural seam**: `SettingsStore` against an
  ephemeral `UserDefaults(suiteName:)` (it already has `init(defaults:)`); the P0.2
  `HistoryPersistenceDecision`, P0.3 capture-health predicate, and P0.2 AX-confirmed-password
  branch as **pure FabCore reducers** (the branch's established, tested pattern) — this is why
  capture-failure and history-skip logic move into FabCore rather than being tested through a
  fake recorder, which `AppController` has no injection point for (F9).
- Regression tests for each fix land beside their reducer.

## 4. Error handling rules (invariants + carve-outs)

- Transcripts are never silently lost on any **completed** dictation path. Two carve-outs,
  both by design: (1) a crash or force-quit **mid-recording** loses the in-flight utterance —
  audio is never written to disk (privacy invariant), so it is unrecoverable; (2) an
  **AX-confirmed** secure-input (password) dictation lives only on a concealed clipboard for
  ≤ 60 s and is not recorded. A secure-input refusal on a non-password field is **not** a
  carve-out — it records normally.
- LLM cleanup can only improve or no-op (untouched). Streaming failures degrade to batch over
  the full untrimmed buffer (untouched). Screen text stays memory-only, logged as counts
  (strengthened by P1.4) and demoted to bias-only authority (P1.2).

## 5. Done criteria

1. P0–P2 items landed; P3 tests in place.
2. `swift test` green including new regression tests; zero warnings under strict
   concurrency; `FAB_REAL_ASR=1` suite still passes.
3. **Manifest verification does not measurably regress model-load latency** (size+mtime
   precheck confirmed; timed against a large Whisper load).
4. Manual smoke on Kal's machine: normal dictation each engine; device unplug mid-recording
   shows the failure notice and keeps the partial transcript; **Accessibility revoked
   mid-session surfaces a notice** (F11); dictation into a real password field leaves no
   history row and clears the clipboard after 60 s; dictation into a normal field while
   another app holds secure input still records; fresh model download writes + verifies a
   manifest; a clipboard manager (if installed) shows no transient dictation entries.
5. **Public-flip gate satisfied** = P0 + P1 merged; workstream 2 (Package) may start.

## 6. Deferred (recorded, not lost)

- **Workstream 2 (Package):** LICENSE; README rewrite (stale "planned" features, screenshots,
  troubleshooting); prune tracked AI-session artifacts (`docs/plans/*`, `docs/superpowers/
  plans/*`, incl. the two `2026-07-07-parakeet-fix` docs the P0.1 merge adds — absolute paths
  throughout); `docs/architecture.md` staleness (omits ScreenReader/PostProcessing, says 5
  modules); **app-level `PrivacyInfo.xcprivacy`** (required-reason API — UserDefaults at
  minimum — + `NSPrivacyTracking false`; the GRDB dep already ships one, we don't);
  dependabot; CONTRIBUTING/SECURITY.md/issue+PR templates; Developer-ID signing +
  notarization + hardened runtime; **auto-update mechanism (Sparkle)** — and note the
  "every update resets TCC" framing only holds for the current ad-hoc/dev signing; once
  Developer-ID-signed the signature is stable and TCC grants survive updates; bundle-ID
  now-or-never decision; SHA-256 checksum on the released dmg; `.claude/settings.local.json`
  currently tracked.
- **Workstream 3 (Roadmap):** competitive positioning; full VoiceOver pass on
  settings/onboarding; localization (currently en-only, single `NSMicrophoneUsageDescription`).
- **Explicitly not doing:** AppController module split; history-at-rest encryption and SQLite
  0600 (defense-in-depth — revisit if history ever syncs); active latency targets; upstream
  supply-chain *authentication* (needs signed model releases upstream, out of our control).
