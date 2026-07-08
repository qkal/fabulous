# Packaging for public release

**Date:** 2026-07-08
**Status:** Design — awaiting review
**Workstream:** 2 of 3 (Harden → **Package** → Roadmap). Workstream 1 (Harden) shipped
via PR #9 (`469a189` on main). This spec covers Package only.

## 1. Goal & context

Turn the hardened codebase into a **public open-source repo** plus a polished
**unsigned** end-user distribution. Two foundational decisions (2026-07-08) shape the
scope:

- **Public open-source repo.** The repo flips public. Full OSS file set. (The old
  "keep private for 10× CI minutes" concern dissolves — public repos get free Actions
  minutes.)
- **Defer code signing.** No Apple Developer Program membership yet, so Developer-ID
  signing, notarization, hardened runtime, and Sparkle auto-update are **out of scope**
  and become a future mini-workstream ("WS2b: signing"). This workstream ships the
  current **unsigned** dmg with a clear install guide + checksum.

Further decisions: **LICENSE = GPL-3.0**; **bundle ID → `io.github.qkal.fabulous`**;
**README screenshots deferred** (prose + placeholders now); **untrack all AI-session
docs** (`docs/plans/`, `docs/superpowers/`, `docs/specs/`), keeping a refreshed
`docs/architecture.md` as the single public design doc.

All work lands on a `packaging` branch → PR → merge. The **repo-public flip is a
separate, gated, final manual step** after merge.

## 2. Deliverables

### A. Legal & community files
- `LICENSE` — GPL-3.0 full text; copyright line "Copyright (C) 2026 Kal".
- `CONTRIBUTING.md` — build/test/PR flow; the SwiftPM-only rule (no `.xcodeproj`, arm64
  only); Swift 6 **zero-warnings** requirement; `swift test` (Swift Testing) as the gate;
  pointer to `docs/architecture.md`.
- `SECURITY.md` — private disclosure path (email), supported-version statement, scope
  (on-device app; no server). Explicitly note the app is unsigned today and how users
  verify the download (SHA-256).
- `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1, contact = same as SECURITY.
- `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`,
  `.github/ISSUE_TEMPLATE/config.yml` (blank-issues off), `.github/PULL_REQUEST_TEMPLATE.md`.

### B. Bundle-ID rename → `io.github.qkal.fabulous`
- `Support/Info.plist:12` `CFBundleIdentifier`.
- Scrub the surname from tracked non-session files (CLAUDE.md gotchas/status; the
  hardening spec mention is untracked in §F anyway).
- **No hardcoded reads** of the old ID exist in Swift/scripts (verified: only Info.plist).
  `SMAppService` (launch-at-login) reads the running bundle's ID, so no code change.
- Consequence: a one-time TCC re-prompt (Mic/Accessibility) on the dev machine — expected,
  verified in smoke, not a regression.

### C. Privacy manifest
- `Support/PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, empty
  `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes` = one entry
  `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1` (app's own defaults).
- `build.sh` copies it into the bundle (`Contents/Resources/PrivacyInfo.xcprivacy` per
  Apple's app-bundle convention).

### D. README rewrite
Replace the stale content (line 11 says Parakeet/SpeechAnalyzer "planned" — both shipped).
New structure:
- One-line pitch + what it is (native on-device macOS voice dictation, menu-bar app).
- **Features**: hold-hotkey dictation; 3 engines (Whisper default, Apple SpeechAnalyzer,
  Parakeet) via the General engine picker; streaming partials; LLM cleanup (Apple
  Foundation Models); screen-context vocabulary; per-app injection overrides; replacements
  editor; transcript history; Paper/Glass themes; latency metrics.
- **Requirements**: Apple Silicon; macOS 14+ base; **macOS 26+** for LLM cleanup,
  SpeechAnalyzer engine, and screen context.
- **Install (unsigned)**: download dmg from Releases → **verify SHA-256** → drag to
  Applications → clear quarantine (`xattr -dr com.apple.quarantine …`) → grant Mic +
  Accessibility. State plainly it is unsigned (no paid Developer ID yet) and what that means.
- **Usage**, **Privacy** (on-device; audio never written to disk; history opt-in and local;
  screen text memory-only), **Troubleshooting/FAQ** (grants revoked, model download, first-run
  CoreML specialization delay, engine availability by OS).
- **How it compares** — brief, honest positioning vs Wispr Flow / superwhisper / MacWhisper
  (on-device, open-source, free, unsigned; not a cloud product).
- Screenshot **placeholders** (`<!-- screenshot: … -->`) for menu, overlay pill, settings.
- License badge (GPL-3.0), Contributing pointer, link to `docs/architecture.md`.
- Remove any dead private-repo release link assumptions.

### E. Supply-chain hygiene
- `.github/dependabot.yml` — two ecosystems: `github-actions` and `swift` (SwiftPM),
  weekly, grouped minor/patch.
- `release.yml` — after the dmg is built, compute `shasum -a 256 fabulous-<v>.dmg >
  fabulous-<v>.dmg.sha256` and attach BOTH to the GitHub Release. README documents the
  verify step against this file.

### F. Repo cleanup
- `.gitignore` += `docs/plans/`, `docs/superpowers/`, `docs/specs/`,
  `.claude/settings.local.json`; then `git rm -r --cached` those paths (files stay on disk
  locally). This untracks all AI-session plans/specs (absolute `/Users/kal` paths) and the
  local settings file.
- **Keep + refresh** `docs/architecture.md`: fix "five library modules" → eight library
  targets, add `ScreenReader` and `PostProcessing`, correct the data-flow (Silero-first VAD;
  LLM cleanup shipped, not "later"; opt-in history shipped). This becomes the sole tracked
  design doc the README links to.
- Note: this packaging spec and its implementation plan live under `docs/superpowers/` and
  are therefore **untracked by this same step** — intentional. They stay on disk locally as
  session records; the public tree keeps only `docs/architecture.md`. Do the `git rm --cached`
  as the last content task, after all other deliverables are committed.

### G. CLAUDE.md
- Update the bundle-ID reference; mark Workstream 2 done and signing deferred in the
  State/roadmap section.

### H. Repo-public flip (separate, gated, LAST)
- `gh repo edit qkal/fabulous --visibility public` — run only after A–G merge to main AND
  Kal explicitly approves. Not part of the PR; a deliberate one-command step. (Reversible to
  private, but published/cached code is effectively public once flipped — hence the gate.)

## 3. Out of scope → future "WS2b: signing"
Developer-ID signing, notarization, hardened runtime, Sparkle auto-update, and real
screenshot/GIF capture. Each waits on the Apple Developer account. The README's install
section is written so a later "Signed builds" addition is additive, not a rewrite.

## 4. Sequencing & safety
1. Branch `packaging` off current `main`.
2. B (bundle-ID) + C (PrivacyInfo) first — they touch the build; verify `swift build`/`swift
   test` green and `scripts/build.sh` produces a bundle with the new ID and the manifest
   present, then `open build/fabulous.app` smoke (Kal confirms the one-time grant re-prompt).
3. A, D, E, F, G — docs/config, independent, any order.
4. PR → review → merge.
5. **H** — the flip, on Kal's explicit go.

## 5. Testing / done criteria
1. `swift build --arch arm64` + `swift test` green, zero warnings in our targets (the
   bundle-ID and manifest changes must not regress the build/tests).
2. `CONFIG=debug scripts/build.sh` yields `build/fabulous.app` whose `Info.plist` shows
   `io.github.qkal.fabulous` and whose `Contents/Resources/` contains `PrivacyInfo.xcprivacy`.
3. `git ls-files docs .claude` shows only `docs/architecture.md` tracked under `docs/`, and
   no `.claude/settings.local.json`.
4. README has no "planned" claims for shipped features; all relative links resolve; install
   section includes the SHA-256 verify step.
5. `release.yml` dry-run (or next tag) attaches `<dmg>.sha256` next to the dmg.
6. Manual smoke (Kal): rebuilt app launches, re-prompts for Mic/Accessibility once (new
   bundle ID), dictation still works.
7. **Flip gate**: A–G merged; Kal approves → repo public.

## 6. Deferred (recorded)
- WS2b signing (above). WS3 competitive roadmap. Real screenshots/GIF. `FUNDING.yml`
  (skip until desired). `CODEOWNERS` (single maintainer — skip).
