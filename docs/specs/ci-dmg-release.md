# CI + .dmg release pipeline

Status: approved design, not yet implemented
Date: 2026-07-03

## Goal

Two GitHub Actions workflows: continuous build+test on every push/PR, and a
tag-triggered release that packages `fabulous.app` into a downloadable .dmg
attached to a GitHub Release.

Decisions made during brainstorming:

- **Unsigned distribution.** No Apple Developer Program membership, and not
  getting one. Releases are ad-hoc signed; users run the documented
  Gatekeeper workaround once. Revisit only if a Developer ID cert appears
  (`scripts/build.sh` already has the hardened-runtime branch ready).
- **Public repo** — macOS runners are free; no minute-budget constraints.
- **Tag push triggers releases** (`v*`), not manual dispatch or draft
  releases.
- **Pretty dmg** via `create-dmg` (background image, positioned icons),
  not a bare `hdiutil` image.

## Constraints

- Runner must be `macos-26` **pinned**. SpeechAnalyzer code requires the
  macOS 26 SDK (local toolchain: Xcode 26.6 / Swift 6.3). `macos-latest`
  may lag behind and would fail the build with confusing availability
  errors; a pinned image that GitHub retires fails visibly at runner
  selection instead.
- arm64 only, matching the repo rule (`swift build --arch arm64`).
- No .xcodeproj — everything goes through SwiftPM + `scripts/build.sh`.
- Third-party GitHub Actions kept to `actions/checkout` + `actions/cache`.
  Release creation uses the preinstalled `gh` CLI; dmg uses Homebrew
  `create-dmg`.

## 1. CI workflow — `.github/workflows/ci.yml`

Triggers: push to `main`, pull requests targeting `main`.

Steps:

1. Checkout.
2. Select Xcode 26 explicitly (`sudo xcode-select -s`), failing loudly if
   the expected version is absent from the image.
3. Restore SwiftPM cache: `.build` and
   `~/Library/Caches/org.swift.swiftpm`, keyed on `Package.resolved`
   (restore-keys fallback on OS/image).
4. `swift build --arch arm64`
5. `swift test`

Notes:

- Concurrency group per ref with `cancel-in-progress: true` — pushes to a
  PR cancel the superseded run.
- Real-engine tests self-skip on CI: `SpeechAnalyzerBackendTests` gate on
  `FAB_REAL_ASR=1` (never set in CI), `SileroVADTests` skip when the VAD
  model is absent. No CI-specific test configuration needed.
- No `-warnings-as-errors`: CI runs exactly what a developer runs locally.
  The zero-warnings policy stays a review-time rule.

## 2. Release workflow — `.github/workflows/release.yml`

Trigger: push of a tag matching `v*` (e.g. `v0.1.0`).
Permissions: `contents: write` (release creation). `GITHUB_TOKEN` only —
no other secrets exist in this pipeline.

Steps after the same checkout/Xcode/cache setup as CI:

1. `swift test` — a broken release is blocked before packaging.
2. **Version stamp**: strip the leading `v` from the tag; write it to
   `CFBundleShortVersionString` in `Support/Info.plist` via PlistBuddy;
   set `CFBundleVersion` to the workflow run number. The checked-in plist
   keeps a `0.0.0-dev` placeholder — CI never commits the stamp back, so
   there is no version drift between git and tags. Local builds honestly
   show `0.0.0-dev`.
3. `scripts/build.sh` — unchanged. CI has no signing identity, so the
   script's ad-hoc branch runs (accepted: unsigned distribution).
4. `scripts/make-dmg.sh` → `fabulous-<version>.dmg` (section 3).
5. `gh release create "$TAG" fabulous-<version>.dmg` with auto-generated
   notes plus an appended install section:
   - **Apple Silicon only** (arm64 binary; Intel Macs not supported)
   - drag app to Applications
   - `xattr -dr com.apple.quarantine /Applications/fabulous.app`
     (recursive — quarantine is set on files inside the bundle too)
   - one line on *why* (unsigned; no Apple Developer certificate)
   - **updating**: each release carries a fresh ad-hoc signature, so
     macOS revokes Microphone/Accessibility grants on update — users
     must re-grant both after installing a new version.

   Flag caveat: verify at implementation whether `--generate-notes`
   composes with `--notes-file` (docs suggest provided notes are
   prepended). Fallback: fetch generated notes via
   `gh api repos/{repo}/releases/generate-notes`, concatenate, pass as
   one `--notes-file`.

Accepted quirk: the workflow fires on any `v*` tag, even one on a
non-main commit. Single-maintainer repo; not worth a ref guard.

## 3. dmg packaging — `scripts/make-dmg.sh`

New script, runnable locally (so the dmg can be verified without pushing a
tag). Inputs: `build/fabulous.app` must exist; version string as `$1` (or
derived from Info.plist). Output: `fabulous-<version>.dmg` in `build/`.

- Tool: `create-dmg` (Homebrew). The release workflow runs
  `brew install create-dmg`; the script errors with an install hint when
  the tool is missing locally.
- Layout: window ≈600×400, app icon left, `/Applications` symlink right,
  icon size 128.
- Background: `Support/dmg-background@2x.png`, committed. Simple generated
  image — app name + arrow, paper-tone matching the app's UI. Swappable
  any time without touching the script.
- Headless CI: Finder scripting is unreliable on runners — the script
  passes `--skip-jenkins` (create-dmg's headless mode) when `CI` is set,
  and retries once on failure before hard-failing. Icon layout is
  verified by running the script locally, where Finder scripting works.

## 4. Documentation changes

- `README.md`: new **Install** section — Apple Silicon requirement,
  download latest dmg from Releases, drag to Applications, run the
  `xattr -dr` command, short explanation that the app is unsigned, and
  the update caveat: Mic/Accessibility permissions must be re-granted
  after every update (ad-hoc signature changes per release).
- `CLAUDE.md`: move the release pipeline from "Not yet built" to the done
  list; one-line pointer to this spec.

## 5. Failure modes

| Failure | Behavior |
| --- | --- |
| SwiftPM cache miss | Slow build (WhisperKit compile), not a failure |
| `macos-26` image retired | Visible runner-selection failure, not a compile mystery |
| Xcode 26 missing from image | Explicit check in the Xcode-select step fails with a clear message |
| `create-dmg` Finder flake | One retry inside `make-dmg.sh`, then hard fail |
| Tests fail on a tag | Release blocked; no dmg published |

## 6. Verification plan

- CI workflow proves itself on the PR/push that introduces it.
- `scripts/make-dmg.sh` is run locally first: build, package, mount the
  dmg, drag-install, launch.
- Release path proved end-to-end by pushing a `v0.0.1` test tag; the tag
  and release are deleted afterwards if unwanted.
