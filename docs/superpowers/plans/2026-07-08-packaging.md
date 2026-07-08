# Packaging for Public Release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the hardened fabulous codebase into a public GPL-3.0 open-source repo plus a polished **unsigned** distribution — legal/community files, bundle-ID rename, privacy manifest, README rewrite, supply-chain hygiene, and a clean public doc surface.

**Architecture:** Almost entirely docs + build/CI config; two tasks touch the build (bundle-ID, privacy manifest) and must keep `swift build`/`swift test` green. Work lands on the `packaging` branch (already created off `main`, holds the spec at `75cb30a`). The repo-public flip is a **separate gated manual step, NOT a task in this plan**.

**Tech Stack:** SwiftPM (arm64, no `.xcodeproj`), macOS app bundle assembled by `scripts/build.sh`, GitHub Actions (`release.yml`), Markdown docs.

## Global Constraints

- `swift build --arch arm64` + `swift test` stay green, **zero warnings in our targets** (a pre-existing FluidAudio dependency resource warning is acceptable). Copied from CLAUDE.md.
- SwiftPM only — never generate an `.xcodeproj`; arm64 only.
- New bundle identifier is exactly `io.github.qkal.fabulous` (verbatim).
- LICENSE is **GPL-3.0** (full canonical text); copyright holder line: `Copyright (C) 2026 Kal`.
- **Defer signing**: no Developer-ID signing, notarization, hardened runtime, or Sparkle in this plan (future "WS2b"). The app is distributed **unsigned**; docs say so plainly.
- Screenshots are **placeholders** only (`<!-- screenshot: … -->`), no capture this plan.
- Keep only `docs/architecture.md` tracked under `docs/` after the cleanup task; untrack `docs/plans/`, `docs/superpowers/`, `docs/specs/`, and `.claude/settings.local.json`.
- GitHub repo: `qkal/fabulous`. Project convention `io.github.<user>`.

**Spec:** `docs/superpowers/specs/2026-07-08-packaging-design.md` (deliverables A–H).

> Do tasks roughly in order: Task 1–2 (build-touching) first, then the docs/config tasks, and **Task 9 (untrack) last** since it removes this plan and the spec from tracking.

---

### Task 1: Bundle-ID rename → `io.github.qkal.fabulous` (spec B)

**Files:**
- Modify: `Support/Info.plist:12` (CFBundleIdentifier), `:30` (NSHumanReadableCopyright)
- Modify: `CLAUDE.md` (the `com.czapkovicz.fabulous` mention in the Gotchas/TCC section)

**Interfaces:** none (identity change).

- [ ] **Step 1: Confirm nothing reads the old ID at runtime**

Run:
```bash
cd /Users/kal/fabulous
grep -rn "com.czapkovicz\|czapkovicz\|bundleIdentifier" Sources scripts Support --include=*.swift --include=*.sh --include=*.plist
```
Expected: the only `com.czapkovicz.fabulous` hit is `Support/Info.plist:12`. If any `Bundle.main.bundleIdentifier` read appears in `Sources`, STOP and report it — a defaults-suite or SMAppService keyed on a literal old ID would need updating too. (Expected: none; `SettingsStore` uses `UserDefaults.standard`, `SMAppService` reads the running bundle.)

- [ ] **Step 2: Rename the identifier**

Edit `Support/Info.plist:12`:
```xml
	<string>io.github.qkal.fabulous</string>
```

- [ ] **Step 3: Fill the copyright string**

Edit `Support/Info.plist:30` (currently empty):
```xml
	<string>Copyright (C) 2026 Kal. GPL-3.0-or-later.</string>
```

- [ ] **Step 4: Scrub the CLAUDE.md mention**

In `CLAUDE.md`, replace any `com.czapkovicz.fabulous` occurrence with `io.github.qkal.fabulous` (grep it: `grep -n czapkovicz CLAUDE.md`). Do not touch other content in this task.

- [ ] **Step 5: Verify build + tests + bundle**

Run:
```bash
swift build --arch arm64 2>&1 | tail -2
swift test 2>&1 | tail -2
CONFIG=debug scripts/build.sh >/dev/null 2>&1 && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" build/fabulous.app/Contents/Info.plist
```
Expected: build clean, tests green, and the last line prints `io.github.qkal.fabulous`.

- [ ] **Step 6: Commit**

```bash
git add Support/Info.plist CLAUDE.md
git commit -m "chore: rename bundle ID to io.github.qkal.fabulous + fill copyright (WS2 B)"
```

> Manual (Kal, later smoke): first launch of the renamed app re-prompts for Microphone + Accessibility once — expected, the new ID is a fresh TCC identity.

---

### Task 2: Privacy manifest (spec C)

**Files:**
- Create: `Support/PrivacyInfo.xcprivacy`
- Modify: `scripts/build.sh` (after line 25, copy the manifest into `Contents/Resources/`)

**Interfaces:** none.

- [ ] **Step 1: Create the manifest**

Create `Support/PrivacyInfo.xcprivacy`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Copy it into the bundle**

In `scripts/build.sh`, immediately after the line `cp Support/Info.plist "${APP}/Contents/Info.plist"` (line 25), add:
```bash
cp Support/PrivacyInfo.xcprivacy "${APP}/Contents/Resources/PrivacyInfo.xcprivacy"
```

- [ ] **Step 3: Verify the manifest lands in the bundle**

Run:
```bash
CONFIG=debug scripts/build.sh >/dev/null 2>&1 && test -f build/fabulous.app/Contents/Resources/PrivacyInfo.xcprivacy && plutil -lint build/fabulous.app/Contents/Resources/PrivacyInfo.xcprivacy
```
Expected: prints `… OK` (valid plist present in the bundle).

- [ ] **Step 4: Commit**

```bash
git add Support/PrivacyInfo.xcprivacy scripts/build.sh
git commit -m "feat: app-level PrivacyInfo.xcprivacy (UserDefaults reason, no tracking) (WS2 C)"
```

---

### Task 3: LICENSE — GPL-3.0 (spec A)

**Files:**
- Create: `LICENSE`

**Interfaces:** none.

- [ ] **Step 1: Write the canonical GPL-3.0 text**

Write the **complete, verbatim** GNU General Public License v3.0 into `LICENSE`. The canonical text is fixed — fetch it exactly:
```bash
cd /Users/kal/fabulous
curl -fsSL https://www.gnu.org/licenses/gpl-3.0.txt -o LICENSE
```
If offline, paste the exact GPL-3.0 text from a known-good copy (must begin with `                    GNU GENERAL PUBLIC LICENSE` / `                       Version 3, 29 June 2007` and end with the `<https://www.gnu.org/licenses/>` line). Do NOT paraphrase or truncate — SPDX/GitHub license detection requires the exact text.

- [ ] **Step 2: Verify it is the real GPL-3.0**

Run:
```bash
head -2 LICENSE && wc -l LICENSE && grep -c "GNU GENERAL PUBLIC LICENSE" LICENSE
```
Expected: first two lines are the GPL-3.0 title + `Version 3, 29 June 2007`; ~674 lines; at least one title match. (GitHub will show "GPL-3.0" in the repo sidebar once this exact text is present.)

- [ ] **Step 3: Commit**

```bash
git add LICENSE
git commit -m "docs: add GPL-3.0 LICENSE (WS2 A)"
```

---

### Task 4: Community-health files (spec A)

**Files:**
- Create: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, `.github/ISSUE_TEMPLATE/config.yml`, `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:** none.

- [ ] **Step 1: CONTRIBUTING.md**

Create `CONTRIBUTING.md`:
```markdown
# Contributing to fabulous

Thanks for your interest! fabulous is a native macOS voice-dictation app built
as a plain SwiftPM package (no Xcode project).

## Prerequisites

- Apple Silicon Mac, macOS 14+ (macOS 26+ to work on the LLM-cleanup,
  SpeechAnalyzer, or screen-context features).
- Xcode 26+ (for the Swift 6 toolchain).

## Build & test

```sh
swift build --arch arm64      # compile (arm64 only — never add x86_64)
swift test                    # unit tests (Swift Testing, not XCTest)
scripts/build.sh              # → build/fabulous.app
```

Ground rules:

- **SwiftPM only.** Do not generate or commit an `.xcodeproj`.
- **Zero warnings.** The codebase compiles clean under Swift 6 strict
  concurrency; keep it that way (a pre-existing FluidAudio dependency
  warning is the only accepted exception).
- **Tests are Swift Testing** (`import Testing`, `@Test`/`#expect`), not XCTest.
  Add tests for new logic; prefer extracting pure decisions into `FabCore`
  where they can be unit-tested.
- Match the surrounding style; keep files focused.

## Pull requests

1. Branch off `main`.
2. Keep commits small and focused; run `swift build` + `swift test` before pushing.
3. Open a PR describing what changed and why. CI (macOS, `swift build` +
   `swift test`) must pass.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the module layout and
data flow before making structural changes.

## License

By contributing, you agree your contributions are licensed under GPL-3.0-or-later.
```

- [ ] **Step 2: SECURITY.md**

Create `SECURITY.md`:
```markdown
# Security Policy

## Reporting a vulnerability

Please report security issues privately by email to **czapkovicz@gmail.com**
with the subject line `fabulous security`. Do not open a public issue for
undisclosed vulnerabilities.

Include what you found, how to reproduce it, and the impact. We aim to
acknowledge within a few days.

## Scope

fabulous is an on-device macOS app with no server component. Relevant areas:

- Local data at rest: transcript history (`~/Library/Application Support/fabulous/history.sqlite`,
  opt-in, plaintext SQLite) and downloaded models.
- Text injection into other apps via the Accessibility API.
- On-device LLM cleanup and AX-harvested screen context (memory-only).

## Distribution integrity

Released builds are currently **unsigned** (no paid Apple Developer ID yet).
Each release attaches a `SHA-256` checksum file next to the `.dmg`; verify it
before opening:

```sh
shasum -a 256 -c fabulous-<version>.dmg.sha256
```

Signed + notarized builds are planned.

## Supported versions

Only the latest release is supported.
```

- [ ] **Step 3: CODE_OF_CONDUCT.md**

Write the **Contributor Covenant v2.1** verbatim into `CODE_OF_CONDUCT.md`. Fetch the canonical text:
```bash
curl -fsSL https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md -o CODE_OF_CONDUCT.md
```
Then set the enforcement contact: replace the placeholder `[INSERT CONTACT METHOD]` with `czapkovicz@gmail.com`:
```bash
sed -i '' 's/\[INSERT CONTACT METHOD\]/czapkovicz@gmail.com/g' CODE_OF_CONDUCT.md
```
Verify no placeholder remains: `grep -c "INSERT CONTACT METHOD" CODE_OF_CONDUCT.md` → expected `0`.

- [ ] **Step 4: Issue + PR templates**

Create `.github/ISSUE_TEMPLATE/bug_report.md`:
```markdown
---
name: Bug report
about: Something isn't working
labels: bug
---

**What happened**
A clear description of the bug.

**Steps to reproduce**
1.
2.

**Expected**
What you expected instead.

**Environment**
- macOS version:
- Mac model (Apple Silicon):
- fabulous version:
- Engine (Whisper / SpeechAnalyzer / Parakeet):

**Logs**
Relevant `fabulous:` lines from Console.app, if any. Do NOT paste transcript
contents you consider private.
```

Create `.github/ISSUE_TEMPLATE/feature_request.md`:
```markdown
---
name: Feature request
about: Suggest an idea
labels: enhancement
---

**Problem**
What are you trying to do that fabulous doesn't support?

**Proposed solution**
What would you like to see?

**Alternatives**
Anything you've considered or worked around.
```

Create `.github/ISSUE_TEMPLATE/config.yml`:
```yaml
blank_issues_enabled: false
```

Create `.github/PULL_REQUEST_TEMPLATE.md`:
```markdown
## What & why

Describe the change and the motivation.

## Checklist

- [ ] `swift build --arch arm64` clean (zero warnings in our targets)
- [ ] `swift test` green
- [ ] Tests added/updated for new logic
- [ ] No `.xcodeproj` added; arm64 only
```

- [ ] **Step 5: Verify**

Run:
```bash
ls CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/ISSUE_TEMPLATE/*.md .github/ISSUE_TEMPLATE/config.yml .github/PULL_REQUEST_TEMPLATE.md
grep -rl "TODO\|TBD\|INSERT CONTACT" CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github || echo "no placeholders"
```
Expected: all files listed; `no placeholders`.

- [ ] **Step 6: Commit**

```bash
git add CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE.md
git commit -m "docs: contributing, security, code of conduct, issue/PR templates (WS2 A)"
```

---

### Task 5: dependabot + dmg SHA-256 checksum (spec E)

**Files:**
- Create: `.github/dependabot.yml`
- Modify: `.github/workflows/release.yml` (Package dmg step ~55–58; Create GitHub Release step ~60–73)

**Interfaces:** none.

- [ ] **Step 1: dependabot config**

Create `.github/dependabot.yml`:
```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      actions:
        patterns: ["*"]
  - package-ecosystem: swift
    directory: /
    schedule:
      interval: weekly
    groups:
      swiftpm:
        update-types: [minor, patch]
```

- [ ] **Step 2: Compute the checksum in the dmg step**

In `.github/workflows/release.yml`, change the `Package dmg` step (the two `run:` lines) to also emit a `.sha256` next to the dmg:
```yaml
      - name: Package dmg
        run: |
          brew install create-dmg
          scripts/make-dmg.sh "${GITHUB_REF_NAME#v}"
          VERSION="${GITHUB_REF_NAME#v}"
          ( cd build && shasum -a 256 "fabulous-${VERSION}.dmg" > "fabulous-${VERSION}.dmg.sha256" )
```

- [ ] **Step 3: Attach the checksum to the release**

In the `Create GitHub Release` step's `gh release create` invocation, add the checksum file as a second asset:
```yaml
          gh release create "${GITHUB_REF_NAME}" \
            "build/fabulous-${VERSION}.dmg" \
            "build/fabulous-${VERSION}.dmg.sha256" \
            --title "fabulous ${VERSION}" \
            --notes-file notes.md
```

- [ ] **Step 4: Verify YAML validity**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/dependabot.yml')); yaml.safe_load(open('.github/workflows/release.yml')); print('yaml ok')"
grep -n "dmg.sha256" .github/workflows/release.yml
```
Expected: `yaml ok`; the `.sha256` file appears in BOTH the Package step (generation) and the release step (attachment).

- [ ] **Step 5: Commit**

```bash
git add .github/dependabot.yml .github/workflows/release.yml
git commit -m "ci: dependabot (actions + swiftpm) + publish dmg SHA-256 checksum (WS2 E)"
```

---

### Task 6: README rewrite (spec D)

**Files:**
- Modify: `README.md` (full replacement)

**Interfaces:** the checksum filename `fabulous-<version>.dmg.sha256` produced by Task 5.

- [ ] **Step 1: Replace README.md entirely**

Overwrite `README.md` with:
```markdown
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

## License

[GPL-3.0-or-later](LICENSE).

## Out of scope

Meeting transcription, diarization, notes/sync, cloud ASR, non-macOS ports,
App Store distribution.
```

- [ ] **Step 2: Verify no stale claims + links resolve**

Run:
```bash
grep -n "planned\|coming\|Whisper-only" README.md || echo "no stale 'planned' claims"
grep -o "\[.*\](\(docs/[^)]*\|LICENSE\|CONTRIBUTING.md\))" README.md | sed 's/.*(\(.*\))/\1/' | while read f; do test -e "$f" && echo "ok $f" || echo "MISSING $f"; done
```
Expected: `no stale 'planned' claims`; every linked path prints `ok …` (note `docs/architecture.md` is refreshed in Task 7 but already exists).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README — shipped features, unsigned-install + checksum, positioning (WS2 D)"
```

---

### Task 7: Refresh docs/architecture.md (spec F)

**Files:**
- Modify: `docs/architecture.md` (the `## Shape` paragraph + module diagram + dictation data-flow block)

**Interfaces:** none.

- [ ] **Step 1: Fix the module count + names**

In `docs/architecture.md`, replace the opening `## Shape` paragraph's "five library modules" with the real set. Change:
```
A menu bar app (`LSUIElement`) built as a SwiftPM package of five library
modules plus one executable.
```
to:
```
A menu bar app (`LSUIElement`) built as a SwiftPM package of eight library
targets plus one executable: FabCore, AudioCapture, HotkeyEngine,
TranscriptionEngine, TextInjector, HistoryStore, ScreenReader, and
PostProcessing. Feature targets depend only on `FabCore`; the executable is
the only place everything meets. `TranscriptionEngine` is the only target that
imports WhisperKit and FluidAudio; `HistoryStore` the only one importing GRDB;
`PostProcessing` the only one importing FoundationModels.
```

- [ ] **Step 2: Add the missing modules to the diagram**

In the ASCII module diagram, add `ScreenReader` and `PostProcessing` to the row of feature modules (alongside `HotkeyEngine AudioCapture TranscriptionEngine TextInjector HistoryStore`). Keep the box drawing readable — a second line under the row is fine, e.g.:
```
         HotkeyEngine AudioCapture TranscriptionEngine TextInjector
              HistoryStore  ScreenReader  PostProcessing
```

- [ ] **Step 3: Correct the data-flow block**

Replace the stale lines in the "Dictation data flow" block:
- `EnergyVAD trims leading/trailing silence` → `Silero VAD (EnergyVAD fallback) trims leading/trailing silence`
- `TextPostProcessor pipeline        (passthrough → dictionary → LLM later)` → `TextPostProcessor pipeline    (passthrough → replacements → optional on-device LLM cleanup)`
- If the block still implies Whisper-only, note the backend line is one of Whisper / SpeechAnalyzer / Parakeet.

- [ ] **Step 4: Verify freshness**

Run:
```bash
grep -n "five library\|LLM later\|EnergyVAD trims" docs/architecture.md || echo "stale phrases gone"
grep -c "ScreenReader\|PostProcessing" docs/architecture.md
```
Expected: `stale phrases gone`; count ≥ 2.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: refresh architecture — 8 targets, Silero-first, LLM shipped (WS2 F)"
```

---

### Task 8: CLAUDE.md roadmap update (spec G)

**Files:**
- Modify: `CLAUDE.md` (State/roadmap section)

**Interfaces:** none.

- [ ] **Step 1: Mark WS2 done + signing deferred**

In `CLAUDE.md`'s "State / roadmap" section, append a line recording that public-readiness packaging shipped and signing is deferred:
```
public-readiness packaging (docs/superpowers/specs/2026-07-08-packaging-design.md):
GPL-3.0 LICENSE, bundle-ID io.github.qkal.fabulous, PrivacyInfo.xcprivacy,
README rewrite, dependabot + dmg SHA-256, community-health files, AI-session
docs untracked (architecture.md kept). Repo flipped public. DEFERRED to a future
"signing" workstream: Developer-ID signing, notarization, hardened runtime,
Sparkle auto-update, real screenshots (needs an Apple Developer account).
```
(The bundle-ID mention was already fixed in Task 1.)

- [ ] **Step 2: Verify**

Run:
```bash
grep -n "packaging\|io.github.qkal.fabulous" CLAUDE.md | head
grep -c "com.czapkovicz" CLAUDE.md
```
Expected: the packaging line present; `com.czapkovicz` count `0`.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — WS2 packaging done, signing deferred (WS2 G)"
```

---

### Task 9: Untrack AI-session docs + local settings (spec F) — **DO LAST**

**Files:**
- Modify: `.gitignore`
- Untrack (keep on disk): `docs/plans/`, `docs/superpowers/`, `docs/specs/`, `.claude/settings.local.json`

**Interfaces:** none. Run this **after every other task is committed** — it removes this plan and the packaging spec from tracking (intentional; they remain on disk).

- [ ] **Step 1: Extend .gitignore**

Append to `.gitignore`:
```
# AI-session design docs + local plans (kept on disk, not published)
docs/plans/
docs/superpowers/
docs/specs/
# Local Claude Code settings
.claude/settings.local.json
```

- [ ] **Step 2: Untrack the paths (files stay on disk)**

Run:
```bash
cd /Users/kal/fabulous
git rm -r --cached docs/plans docs/superpowers docs/specs .claude/settings.local.json
```
Expected: git reports the files as removed from the index; `ls docs/superpowers` still shows them on disk.

- [ ] **Step 3: Verify the public docs surface**

Run:
```bash
git ls-files docs
git ls-files .claude
```
Expected: `git ls-files docs` prints exactly `docs/architecture.md` (nothing else under `docs/`); `git ls-files .claude` prints nothing (or only non-local settings if any exist).

- [ ] **Step 4: Confirm build/tests still green (sanity — no source touched)**

Run:
```bash
swift build --arch arm64 2>&1 | tail -1 && swift test 2>&1 | tail -1
```
Expected: build complete, tests pass.

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: untrack AI-session docs + local settings; keep architecture.md (WS2 F)"
```

---

## Final verification

- [ ] **Whole-branch sanity**

Run:
```bash
cd /Users/kal/fabulous
swift build --arch arm64 2>&1 | tail -1
swift test 2>&1 | tail -1
CONFIG=debug scripts/build.sh >/dev/null 2>&1 && \
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" build/fabulous.app/Contents/Info.plist && \
  test -f build/fabulous.app/Contents/Resources/PrivacyInfo.xcprivacy && echo "bundle ok"
git ls-files docs                       # → only docs/architecture.md
ls LICENSE CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/dependabot.yml Support/PrivacyInfo.xcprivacy
```
Expected: build/tests green; prints `io.github.qkal.fabulous`, `bundle ok`; only `docs/architecture.md` tracked under docs; all files present.

- [ ] **PR** — push `packaging`, open a PR to `main`, let CI run.

---

## Manual gated step — NOT a plan task

**Repo-public flip (spec H).** After the PR merges to `main` **and Kal explicitly approves**, run:
```bash
gh repo edit qkal/fabulous --visibility public --accept-visibility-change-consequences
```
Do NOT run this as part of automated plan execution. It is irreversible in effect (code becomes public/cached). Kal triggers it.

**Deferred → future "WS2b: signing":** Developer-ID signing, notarization, hardened runtime, Sparkle auto-update, real screenshots. Each waits on an Apple Developer Program membership.
