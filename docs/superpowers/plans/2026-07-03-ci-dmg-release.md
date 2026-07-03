# CI + .dmg Release Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub Actions CI (build+test on push/PR) and a tag-triggered release workflow that packages `fabulous.app` into a downloadable .dmg attached to a GitHub Release.

**Architecture:** Two workflows on pinned `macos-26` runners. CI mirrors the local dev loop (`swift build --arch arm64` + `swift test`). Release stamps the version from the git tag into Info.plist, runs the existing `scripts/build.sh` (ad-hoc signing — unsigned distribution is a deliberate decision), packages via a new `scripts/make-dmg.sh` using Homebrew `create-dmg`, and publishes with the preinstalled `gh` CLI.

**Tech Stack:** GitHub Actions (`actions/checkout@v4`, `actions/cache@v4` only), bash, `create-dmg` (Homebrew), PlistBuddy, `gh` CLI, one small Swift/AppKit script for background-image generation.

**Spec:** `docs/specs/ci-dmg-release.md` — read it before starting.

## Global Constraints

- Runner: `macos-26` **pinned** (never `macos-latest` — macOS 26 SDK required for SpeechAnalyzer code).
- arm64 only: `swift build --arch arm64`. Never add x86_64.
- No .xcodeproj. SwiftPM + shell scripts only.
- Third-party actions limited to `actions/checkout` and `actions/cache`.
- Unsigned distribution: CI must NOT get a signing identity; `scripts/build.sh`'s ad-hoc branch is the intended path. Do not modify `scripts/build.sh`.
- Gatekeeper workaround command is exactly: `xattr -dr com.apple.quarantine /Applications/fabulous.app` (recursive `-dr`, not `-d`).
- The repo is at `https://github.com/qkal/fabulous` (origin). Repo must be public before the release test (free macOS runners assumption).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: dmg background asset + generator script

**Files:**
- Create: `scripts/gen-dmg-background.swift`
- Create (generated): `Support/dmg-background@2x.png`

**Interfaces:**
- Produces: `Support/dmg-background@2x.png`, 1200×800 px (600×400 pt @2x), referenced by Task 2's `make-dmg.sh`.

- [ ] **Step 1: Write the generator script**

Create `scripts/gen-dmg-background.swift`:

```swift
// Generates Support/dmg-background@2x.png — the dmg window background.
// One-off tool, committed so the asset is regenerable:
//   swift scripts/gen-dmg-background.swift
// Coordinates assume a 600x400 pt dmg window (create-dmg config lives in
// scripts/make-dmg.sh): app icon at (150,200), Applications link at
// (450,200), so the arrow sits between them at window center.
import AppKit

let size = NSSize(width: 1200, height: 800) // 600x400 @2x
let image = NSImage(size: size)
image.lockFocus()

// Paper tone, matching the app's paper UI theme.
NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.91, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let title = "fabulous" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
]
let tSize = title.size(withAttributes: titleAttrs)
title.draw(
    at: NSPoint(x: (size.width - tSize.width) / 2, y: 620),
    withAttributes: titleAttrs)

let arrow = "→" as NSString
let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 96, weight: .light),
    .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
]
let aSize = arrow.size(withAttributes: arrowAttrs)
arrow.draw(
    at: NSPoint(x: (size.width - aSize.width) / 2, y: 400 - aSize.height / 2),
    withAttributes: arrowAttrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("png encode failed") }
try png.write(to: URL(fileURLWithPath: "Support/dmg-background@2x.png"))
print("wrote Support/dmg-background@2x.png")
```

- [ ] **Step 2: Run it and verify the asset**

```bash
cd /Users/kal/fabulous && swift scripts/gen-dmg-background.swift
sips -g pixelWidth -g pixelHeight Support/dmg-background@2x.png
```

Expected: `wrote Support/dmg-background@2x.png`, then `pixelWidth: 1200`, `pixelHeight: 800`.

- [ ] **Step 3: Visually check** — `open Support/dmg-background@2x.png`; confirm paper-tone background, "fabulous" title near top, centered arrow. (If running non-interactively, Read the PNG file to inspect it.)

- [ ] **Step 4: Commit**

```bash
git add scripts/gen-dmg-background.swift Support/dmg-background@2x.png
git commit -m "feat: dmg background asset + generator

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `scripts/make-dmg.sh`

**Files:**
- Create: `scripts/make-dmg.sh` (chmod +x)

**Interfaces:**
- Consumes: `build/fabulous.app` (from `scripts/build.sh`), `Support/dmg-background@2x.png` (Task 1).
- Produces: `build/fabulous-<version>.dmg`. Called by Task 4's release workflow as `scripts/make-dmg.sh "<version>"`.

- [ ] **Step 1: Write the script**

Create `scripts/make-dmg.sh`:

```bash
#!/usr/bin/env bash
# Packages build/fabulous.app into a distributable dmg with a styled
# window (background, positioned icons, /Applications drop link).
#
# Usage: scripts/make-dmg.sh <version>       # e.g. 0.1.0
# Requires: build/fabulous.app (scripts/build.sh), create-dmg (Homebrew).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-dmg.sh <version>}"
APP="build/fabulous.app"
STAGE="build/dmg-stage"
DMG="build/fabulous-${VERSION}.dmg"

[ -d "${APP}" ] || { echo "error: ${APP} missing — run scripts/build.sh first" >&2; exit 1; }
command -v create-dmg >/dev/null 2>&1 \
  || { echo "error: create-dmg not found — brew install create-dmg" >&2; exit 1; }

# create-dmg takes a source FOLDER; stage the app alone so nothing else
# from build/ leaks into the image.
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"

ARGS=(
  --volname "fabulous ${VERSION}"
  --background "Support/dmg-background@2x.png"
  --window-size 600 400
  --icon-size 128
  --icon "fabulous.app" 150 200
  --app-drop-link 450 200
)
# Finder scripting is unreliable on headless CI runners; create-dmg's
# --skip-jenkins skips the AppleScript-driven Finder styling there.
[ -n "${CI:-}" ] && ARGS+=(--skip-jenkins)

# create-dmg occasionally trips over Finder/AppleScript timing; retry once.
if ! create-dmg "${ARGS[@]}" "${DMG}" "${STAGE}"; then
  echo "==> create-dmg failed, retrying once"
  rm -f "${DMG}"
  create-dmg "${ARGS[@]}" "${DMG}" "${STAGE}"
fi

rm -rf "${STAGE}"
echo "==> done: ${DMG}"
```

```bash
chmod +x scripts/make-dmg.sh
```

- [ ] **Step 2: Verify the failure paths (cheap "tests first" for a shell script)**

```bash
cd /Users/kal/fabulous
rm -rf build/fabulous.app
scripts/make-dmg.sh 0.0.0-test; echo "exit=$?"
scripts/make-dmg.sh; echo "exit=$?"
```

Expected: first run prints `error: build/fabulous.app missing — run scripts/build.sh first`, exit=1. Second prints the usage error from `${1:?…}`, non-zero exit.

- [ ] **Step 3: Install create-dmg locally if absent**

```bash
command -v create-dmg || brew install create-dmg
```

- [ ] **Step 4: Full local run**

```bash
cd /Users/kal/fabulous
scripts/build.sh
scripts/make-dmg.sh 0.0.0-test
```

Expected: ends with `==> done: build/fabulous-0.0.0-test.dmg`. (First build.sh run may be slow — WhisperKit compile. If it fails with `errSecInternalComponent`, unlock the dev keychain: `security unlock-keychain -p fabulous-dev-local ~/Library/Keychains/fabulous-dev.keychain-db`.)

- [ ] **Step 5: Verify dmg contents**

```bash
hdiutil attach build/fabulous-0.0.0-test.dmg -nobrowse -readonly
ls "/Volumes/fabulous 0.0.0-test/"
hdiutil detach "/Volumes/fabulous 0.0.0-test"
```

Expected: listing shows `fabulous.app` and `Applications` (symlink). Background/icon layout can also be eyeballed by opening the mounted volume in Finder.

- [ ] **Step 6: Clean up and commit**

```bash
rm -f build/fabulous-0.0.0-test.dmg
git add scripts/make-dmg.sh
git commit -m "feat: dmg packaging script (create-dmg)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: reusable step sequence (checkout → Xcode select → cache → build/test) that Task 4's release workflow mirrors. No cross-file includes — Task 4 copies the steps.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    # Pinned: the macOS 26 SDK is required (SpeechAnalyzer). If GitHub
    # retires this image the job fails at runner selection — visibly —
    # instead of with availability-check compile errors.
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26
        run: |
          XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
          if [ -z "${XCODE}" ]; then
            echo "::error::No Xcode 26.x on this image. Available:"
            ls /Applications | grep -i xcode || true
            exit 1
          fi
          sudo xcode-select -s "${XCODE}/Contents/Developer"
          xcodebuild -version

      - name: Cache SwiftPM
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          key: swiftpm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
          restore-keys: |
            swiftpm-${{ runner.os }}-

      - name: Build
        run: swift build --arch arm64

      - name: Test
        run: swift test
```

- [ ] **Step 2: Lint the workflow**

```bash
command -v actionlint || brew install actionlint
actionlint .github/workflows/ci.yml
```

Expected: no output (clean).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build + test workflow on macos-26

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Live verification happens in Task 6 — one push proves CI and pre-verifies release steps together.)

---

### Task 4: Release workflow + install notes + version placeholder

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `.github/release-install-section.md`
- Modify: `Support/Info.plist` (CFBundleShortVersionString `0.1.0` → `0.0.0-dev`)

**Interfaces:**
- Consumes: `scripts/make-dmg.sh <version>` (Task 2) producing `build/fabulous-<version>.dmg`; `scripts/build.sh` (existing, untouched).
- Produces: GitHub Release with attached dmg on `v*` tag push.

- [ ] **Step 1: Write the install-notes fragment**

Create `.github/release-install-section.md`:

```markdown

## Install

**Requires an Apple Silicon Mac** (M1 or later — the binary is arm64-only).

1. Download `fabulous-<version>.dmg` below and open it.
2. Drag **fabulous** into **Applications**.
3. The app is not notarized (no Apple Developer certificate — it's a
   free-time project), so macOS will refuse to open it until you clear
   the quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

**Updating from a previous version:** each release carries a fresh
ad-hoc code signature, so macOS revokes the app's Microphone and
Accessibility permissions on update. Re-grant both in System Settings →
Privacy & Security when prompted.
```

- [ ] **Step 2: Set the Info.plist placeholder**

Per spec: git keeps `0.0.0-dev`; only CI stamps real versions — no drift between file and tags.

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.0-dev" Support/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist
```

Expected: `0.0.0-dev`. (Both version keys already exist in the plist; plain `Set` works.)

- [ ] **Step 3: Write the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

jobs:
  release:
    # Pinned for the macOS 26 SDK — see ci.yml.
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode 26
        run: |
          XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1)
          if [ -z "${XCODE}" ]; then
            echo "::error::No Xcode 26.x on this image. Available:"
            ls /Applications | grep -i xcode || true
            exit 1
          fi
          sudo xcode-select -s "${XCODE}/Contents/Developer"
          xcodebuild -version

      - name: Cache SwiftPM
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
          key: swiftpm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}
          restore-keys: |
            swiftpm-${{ runner.os }}-

      - name: Test
        run: swift test

      - name: Stamp version from tag
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Support/Info.plist
          /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER}" Support/Info.plist
          echo "version=${VERSION}"

      - name: Build app bundle
        # No signing identity on CI -> build.sh's ad-hoc branch runs.
        # Unsigned distribution is deliberate; see docs/specs/ci-dmg-release.md.
        run: scripts/build.sh

      - name: Package dmg
        run: |
          brew install create-dmg
          scripts/make-dmg.sh "${GITHUB_REF_NAME#v}"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          # Generated notes via API, then append the install section —
          # sidesteps gh's --generate-notes/--notes-file combination rules.
          gh api "repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
            -f tag_name="${GITHUB_REF_NAME}" --jq .body > notes.md
          cat .github/release-install-section.md >> notes.md
          gh release create "${GITHUB_REF_NAME}" \
            "build/fabulous-${VERSION}.dmg" \
            --title "fabulous ${VERSION}" \
            --notes-file notes.md
```

- [ ] **Step 4: Lint**

```bash
actionlint .github/workflows/release.yml
```

Expected: no output.

- [ ] **Step 5: Dry-run the stamp + notes logic locally**

```bash
cd /Users/kal/fabulous
cp Support/Info.plist /tmp/Info-test.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" /tmp/Info-test.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 42" /tmp/Info-test.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /tmp/Info-test.plist
rm /tmp/Info-test.plist
```

Expected: `9.9.9`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml .github/release-install-section.md Support/Info.plist
git commit -m "ci: tag-triggered dmg release workflow

Version stamped from tag; Info.plist keeps a 0.0.0-dev placeholder.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation (README + CLAUDE.md)

**Files:**
- Modify: `README.md` (add Install section)
- Modify: `CLAUDE.md` (roadmap: release pipeline done; commands: make-dmg)

**Interfaces:**
- Consumes: install instructions matching `.github/release-install-section.md` (Task 4) — keep the two consistent.

- [ ] **Step 1: Add README Install section**

Read `README.md` first; insert after the intro/description (before build-from-source content if present):

```markdown
## Install

Requires an **Apple Silicon** Mac (arm64-only binary) running macOS 14+.

1. Download the latest `fabulous-<version>.dmg` from
   [Releases](https://github.com/qkal/fabulous/releases).
2. Open it and drag **fabulous** into **Applications**.
3. The app is unsigned (no Apple Developer certificate), so clear the
   quarantine flag once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/fabulous.app
   ```

> **Updating:** each release has a fresh ad-hoc signature, so macOS
> revokes Microphone and Accessibility permissions on update — re-grant
> both in System Settings → Privacy & Security.
```

Adjust placement to fit the existing README structure; do not duplicate an existing Install section if one exists (replace it instead).

- [ ] **Step 2: Update CLAUDE.md**

Two edits:

1. In the **Commands** block, after the `open build/fabulous.app` line, add:

```sh
scripts/make-dmg.sh <version>  # → build/fabulous-<version>.dmg (needs create-dmg)
```

2. In **State / roadmap**: remove "signed/notarized .dmg release pipeline" from the not-yet-built list and append to the done list:

```
CI + dmg releases (docs/specs/ci-dmg-release.md): GitHub Actions
build+test on push/PR (macos-26, pinned), tag push v* → unsigned dmg
attached to GitHub Release (create-dmg, version stamped from tag;
Info.plist stays 0.0.0-dev in git).
```

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: install instructions + release pipeline notes

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Live verification (push + test release)

**Files:** none (operational task).

**Interfaces:**
- Consumes: everything above, pushed to `origin` (`https://github.com/qkal/fabulous`).

⚠️ This task pushes to GitHub and publishes a (test) release — outward-facing. If executing autonomously, confirm with Kal before this task unless already authorized.

- [ ] **Step 1: Confirm repo visibility**

```bash
gh repo view qkal/fabulous --json visibility --jq .visibility
```

Expected: `PUBLIC`. If private: stop, ask Kal (macOS minutes bill 10× on private repos — spec assumes public).

- [ ] **Step 2: Push main, watch CI**

```bash
git push origin main
gh run watch --repo qkal/fabulous --exit-status
```

Expected: CI run completes green (first run is slow — cold cache, WhisperKit compile; plausibly 15–30 min).

- [ ] **Step 3: Push test tag, watch release**

```bash
git tag v0.0.1
git push origin v0.0.1
gh run watch --repo qkal/fabulous --exit-status
```

Expected: Release workflow green.

- [ ] **Step 4: Verify the release artifact**

```bash
gh release view v0.0.1 --repo qkal/fabulous
cd /private/tmp/claude-501/-Users-kal-fabulous/aac17b46-73bd-4862-96b1-146387af7fe0/scratchpad
gh release download v0.0.1 --repo qkal/fabulous
hdiutil attach fabulous-0.0.1.dmg -nobrowse -readonly
ls "/Volumes/fabulous 0.0.1/"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "/Volumes/fabulous 0.0.1/fabulous.app/Contents/Info.plist"
hdiutil detach "/Volumes/fabulous 0.0.1"
```

Expected: release notes contain the Install section; volume contains `fabulous.app` + `Applications`; stamped version prints `0.0.1`.

- [ ] **Step 5: Decide fate of v0.0.1 with Kal** — keep as first public release, or delete:

```bash
gh release delete v0.0.1 --repo qkal/fabulous --yes
git push origin :refs/tags/v0.0.1
git tag -d v0.0.1
```

---

## Self-Review Notes

- Spec coverage: CI (Task 3), release+stamp+notes (Task 4), make-dmg+background (Tasks 1–2), docs (Task 5), verification plan (Task 6), failure modes (Xcode check in both workflows, create-dmg retry + `--skip-jenkins` in Task 2, pinned runner comments). `gh` notes-flag caveat resolved by using the generate-notes API directly.
- No placeholders; all code complete.
- Cross-task names consistent: `scripts/make-dmg.sh "<version>"` → `build/fabulous-<version>.dmg`; background path `Support/dmg-background@2x.png`; icon coordinates in Task 1 comment match Task 2 args.
