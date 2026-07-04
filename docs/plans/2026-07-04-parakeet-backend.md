# Parakeet Backend (FluidAudio) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Third transcription engine — Parakeet TDT 0.6b v3 (batch) + Parakeet EOU 120M (streaming) via FluidAudio — behind the Settings → General engine picker, with its models managed in the Models tab.

**Architecture:** `ParakeetBackend` actor in `TranscriptionEngine` implements `TranscriptionBackend` + `StreamingTranscriptionBackend`, confining FluidAudio's types (mirror of `WhisperKitBackend`). FluidAudio does load/decode; our `ParakeetLayout` + `ModelManager` own install/verify/delete/progress. Streaming finals come from the 120M model (accepted trade-off; spec `docs/specs/parakeet-backend.md`); the v3 batch path is the fallback via the existing `StreamingDictation.finalTranscript` seam.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM, FluidAudio (FluidInference), Swift Testing (`@Test`/`#expect`, NOT XCTest).

## Global Constraints

- Build: `cd /Users/kal/fabulous && swift build --arch arm64` (never x86_64, never cd into `.build/checkouts`).
- Tests: `cd /Users/kal/fabulous && swift test` (Swift Testing, not XCTest).
- Zero warnings in our targets under strict concurrency — warnings are defects.
- Only `TranscriptionEngine` may import FluidAudio (same rule as WhisperKit).
- FluidAudio declares its own `Language`; in files importing both FluidAudio and FabCore write `FabCore.Language` for ours. For FluidAudio's own `Language`, `FluidAudio.Language` does NOT compile (Task 1 finding: FluidAudio ships a same-named `public struct FluidAudio {}` namespace shim that shadows the qualifier) — add `import enum FluidAudio.Language` alongside `import FluidAudio` and refer to it as bare `Language`. Same `FabCore.AudioBuffer` qualification rule wherever AVFoundation is imported.
- Transcripts must never be silently lost: every failure path degrades to the batch decode over the full untrimmed buffer via `StreamingDictation.finalTranscript`; downstream safety net untouched.
- Engine-load failure must revert `settings.transcriptionEngine = .whisper` AND explicitly call `loadWhisper()` — `onEngineChanged` no-ops outside `.idle`/`.failed`.
- Commit after every task (small, task-scoped commits).

## Task 1 findings (filled during Task 1 — later tasks consume these)

> RESOLVED. Verified 2026-07-04 by reading `.build/checkouts/FluidAudio`
> (tag v0.15.4) directly — a much richer/newer package than this plan's
> original guesses (v0.9-era API shapes). All values below are real,
> compile-checkable facts, cited by file path in the Task 1 report
> (`.superpowers/sdd/task-1-report.md`).

- FluidAudio version pinned: **v0.15.4** (`.package(url: ..., from: "0.15.4")`;
  highest stable tag, no pre-release suffix, per `git ls-remote --tags` sorted
  with `sort -V`). Platform floor unaffected: FluidAudio itself targets
  macOS 14.0+ / iOS 17.0+ (see its `CLAUDE.md`), so our `.macOS(.v14)` stays.
- v3 repo ID (HuggingFace): `FluidInference/parakeet-tdt-0.6b-v3-coreml`
  (`Repo.parakeetV3` in `ModelNames.swift:6`) — confirmed as originally
  guessed. **Local folder name differs from the HF id**: FluidAudio's own
  download/load path derivation always overrides whatever leaf directory
  name is passed in with `Repo.folderName` — for `.parakeetV3` that's
  `"parakeet-tdt-0.6b-v3"` (`name` minus `-coreml`; see `ModelNames.swift:70-77`
  and the default-case fallback at `ModelNames.swift:256-258`). Empirically
  verified: `AsrModels.load(from:)` and `AsrModels.download(to:)` both do
  `directory.deletingLastPathComponent().appendingPathComponent(repo.folderName)`
  internally (`AsrModels.swift:140-143`, `:241`, `:492`), so **the last path
  component you pass is discarded and replaced** — `ParakeetLayout`'s v3 repo
  root must end in `parakeet-tdt-0.6b-v3`, not the full HF id.
- EOU 120M repo ID (HuggingFace): **`FluidInference/parakeet-realtime-eou-120m-coreml`**
  — NOT `FluidInference/parakeet-eou-120m-coreml` as this plan originally
  guessed. It carries a chunk-size subpath: `.../160ms`, `.../320ms`, or
  `.../1280ms` (`Repo.parakeetEou160/320/1280` in `ModelNames.swift:21-23`).
  We use the default `.ms160` chunk size (160ms latency, ~8-9% WER per the
  doc comment in `StreamingEouAsrManager.swift:19`). Local folder name:
  `"parakeet-eou-streaming/160ms"` (`ModelNames.swift:219`) — again distinct
  from the HF id's `parakeet-realtime-eou-120m-coreml/160ms`.
- v3 required files (int8 encoder precision, our default): `Preprocessor.mlmodelc`,
  `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc` (from
  `ModelNames.ASR.requiredModelsV3(precision: .int8)`, `ModelNames.swift:351-360`)
  plus the shared vocabulary file `parakeet_vocab.json`
  (`ModelNames.ASR.vocabularyFile`, `ModelNames.swift:330`), checked
  separately by `AsrModels.modelsExist` (`AsrModels.swift:592-597`). Measured
  combined size via HuggingFace's tree API (not a local download):
  **~460.7 MB**.
- EOU required files: `streaming_encoder.mlmodelc`, `decoder.mlmodelc`,
  `joint_decision.mlmodelc`, `vocab.json` (all lowercase — distinct naming
  convention from the v3/ASR files) — `ModelNames.ParakeetEOU.requiredModels`,
  `ModelNames.swift:501-516`. Measured combined size (160ms variant) via
  HuggingFace's tree API: **~213.7 MB**.
- Download API that targets a custom directory: **yes.**
  `AsrModels.download(to: URL? = nil, force: Bool = false, version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8, progressHandler: DownloadUtils.ProgressHandler? = nil) async throws -> URL`
  (`AsrModels.swift:483-489`) and
  `AsrModels.downloadAndLoad(to:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:) async throws -> AsrModels`
  (`AsrModels.swift:548-555`). **Caveat** (see repo-ID note above): the `to:`
  directory's last path component is discarded and replaced with
  `version.repo.folderName` — pass the *parent* of
  `ParakeetLayout.repoRoot(...)`, or equivalently pass `repoRoot(...)`
  itself since its last component already equals `folderName` by
  construction. `progressHandler` reports real fractional
  `DownloadProgress.fractionCompleted` (`DownloadUtils.swift:137-153`), not
  coarse two-step progress as this plan assumed — `ParakeetInstaller` should
  forward it directly. No taught-location fallback needed.
- `StreamingEouAsrManager` custom-directory loading: **yes, two ways.**
  `func loadModels(from directory: URL) async throws` (`StreamingEouAsrManager.swift:284`)
  loads flat files directly from `directory` (must directly contain
  `streaming_encoder.mlmodelc`, `decoder.mlmodelc`, `joint_decision.mlmodelc`,
  `vocab.json` — no further folderName derivation, unlike the v3 ASR path).
  `func loadModels(to directory: URL? = nil, configuration: MLModelConfiguration? = nil, progressHandler: DownloadUtils.ProgressHandler? = nil) async throws`
  (`StreamingEouAsrManager.swift:333-337`) downloads-then-loads: it computes
  `modelDir = (directory ?? defaultCacheDir).appendingPathComponent(repo.folderName)`
  (single append, no leaf-discarding) and calls `loadModels(from: modelDir)`.
  So for `ParakeetInstaller`, call the lower-level `DownloadUtils.downloadRepo`
  directly (see below — no standalone static download-only function exists
  for EOU); for `ParakeetBackend.load`, call
  `loadModels(from: ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase:))`.
- Combined size on disk (MB): **~674 MB** (460.7 + 213.7, HuggingFace-API-measured
  file sizes for the exact required file sets above; not yet confirmed against
  an actual on-disk download — re-measure via `ParakeetLayout.sizeOnDisk`
  after Task 9's manual GUI check and correct `ModelDescriptor.parakeetV3.approximateSizeMB`
  if it drifts materially).
- Max usable `eouDebounceMs`: **`Int`, default `1280`, no compiled ceiling**
  (`public var eouDebounceMs: Int = 1280`, `StreamingEouAsrManager.swift:211`;
  same default in the `init` at `:236`). No clamping/validation found in the
  EOU-detection loop (`StreamingEouAsrManager.swift:615-631`) — `600_000`
  (10 minutes) is safely representable and never triggers mid-dictation.
- **Sendable / concurrency (new finding, not in the original checklist but
  required by Task 5/7's `@retroactive @unchecked Sendable` question):**
  both `AsrManager` (`AsrManager.swift:6`, `public actor AsrManager`) and
  `StreamingEouAsrManager` (`StreamingEouAsrManager.swift:163`,
  `public actor StreamingEouAsrManager`) are Swift `actor`s — Sendable by
  the language, not `@unchecked`. **No `@retroactive @unchecked Sendable`
  extension is needed anywhere in Task 5 or Task 7**; that provisional
  comment/code is removed.
- **API shape difference affecting Task 5 (new finding):** `AsrManager.transcribe`
  requires an externalized `decoderState: inout TdtDecoderState` argument in
  every overload (`AsrManager.swift:353-357,478-482`) — there is no
  zero-argument `transcribe(samples)`. `TdtDecoderState()` is a throwing
  init with a default `decoderLayers: Int = 2` (`TdtDecoderState.swift:32`),
  fresh per call is correct for our stateless batch use (no cross-utterance
  decoder state to carry). `ASRResult.text: String` is the transcript
  (`AsrTypes.swift:90`).
- `FluidAudio.Language` exists as documented in CLAUDE.md's existing gotcha
  (`Shared/TokenLanguageFilter.swift:4`, `public enum Language: String, Sendable, CaseIterable`) —
  confirms the `FabCore.Language` qualification requirement is still correct
  and unchanged. **New sub-finding:** `AsrManager.transcribe`'s `language:`
  parameter is typed `FluidAudio.Language?`, not a plain `String?` (unlike
  WhisperKit's backend, which takes `language?.rawValue` directly) — Task 5
  bridges with `language.flatMap { Language(rawValue: $0.rawValue) }`.
- **`FluidAudio.Language` qualification is a bigger gotcha than CLAUDE.md's
  existing entry implies (new finding, empirically verified in a throwaway
  SwiftPM package against the real v0.15.4 checkout — not just source
  reading):** FluidAudio ships a deliberate namespace shim,
  `public struct FluidAudio {}` (`FluidAudioSwift.swift:29`; its own comment
  says "creates a namespace collision"). Once both `FabCore` and `FluidAudio`
  are imported in the same file, **`FluidAudio.Language(...)` does not
  compile** — the compiler resolves `FluidAudio.` to that empty struct, not
  the module, and reports `type 'FluidAudio' has no member 'Language'`. A
  plain unqualified `Language` is ambiguous between `FabCore.Language` and
  FluidAudio's `Language` and fails to compile too. The fix verified to
  actually work: add `import enum FluidAudio.Language` (a scoped/declaration
  import) alongside the ordinary `import FluidAudio` — this brings the
  module's `Language` into unqualified scope with the specificity needed to
  win over `FabCore.Language`, and code refers to it as bare `Language`
  (never `FluidAudio.Language`). Task 5's `ParakeetBackend.swift` uses this;
  Task 11's CLAUDE.md gotcha update should mention the scoped-import
  workaround, not just "qualify with FabCore.Language" (which remains
  correct for FabCore's side but is incomplete advice for FluidAudio's side).

---

### Task 1: FluidAudio dependency + API risk gates

**Files:**
- Modify: `Package.swift:12-19` (dependencies), `Package.swift:32-38` (TranscriptionEngine target)
- Modify: `docs/plans/2026-07-04-parakeet-backend.md` (findings block above)

**Interfaces:**
- Produces: resolved FluidAudio package; verified facts in the findings block. Every `(verify)`/`(fill)` marker in this plan gets resolved here.

- [ ] **Step 1: Find the latest stable tag**

Run: `git ls-remote --tags https://github.com/FluidInference/FluidAudio.git | grep -v '\^{}' | tail -8`
Expected: a list of version tags; note the highest stable (no pre-release suffix).

- [ ] **Step 2: Add the dependency**

In `Package.swift` dependencies array, after the GRDB entry:

```swift
        // FluidAudio: Parakeet (TDT v3 batch, EOU 120M streaming) compiled
        // to CoreML. Used for model loading + decode only; downloads and
        // install management stay ours (ParakeetLayout/ModelManager).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
```

(Step 1 result: `v0.15.4` was the highest stable tag — `git ls-remote --tags`
sorted alphabetically is misleading past v0.9→v0.10; pipe through
`sort -V` to get true semver order.)

In the TranscriptionEngine target:

```swift
        .target(
            name: "TranscriptionEngine",
            dependencies: [
                "FabCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
```

- [ ] **Step 3: Resolve + build**

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: succeeds, zero warnings in our targets. If FluidAudio's macOS floor exceeds `.macOS(.v14)`, raise `platforms` to the minimum FluidAudio requires and note it in the findings block.

- [ ] **Step 4: Verify APIs against the checked-out source (do NOT cd into the checkout)**

Run each from the repo root:

```sh
grep -rn "public static func download" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/ | head -20
grep -rn "func load(from" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/ | head
grep -rn "parakeet-tdt-0.6b-v3\|parakeet-eou\|parakeet_eou\|120m" .build/checkouts/FluidAudio/Sources/FluidAudio/ --include="*.swift" -l | head
grep -rn "mlmodelc\|vocab" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/ --include="*.swift" | grep -i "name\|file\|component" | head -30
grep -rn "class StreamingEouAsrManager\|func loadModels\|eouDebounceMs" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/ | head -20
grep -rn ": Sendable\|@unchecked" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/ | grep -i "AsrManager\|AsrModels\|StreamingEou" | head
```

Answer, from what you read: (a) exact repo IDs for both model sets; (b) required file names per repo; (c) whether a download function takes a destination directory — if yes its exact signature, if no confirm where it caches (expected: an app-support `FluidAudio` folder) and choose the taught-location strategy: `ParakeetLayout` roots point at FluidAudio's cache instead of our tree, and the Models-tab footer copy names that location (Task 9); (d) whether `StreamingEouAsrManager.loadModels()` can load from a directory; (e) whether `AsrManager`/`StreamingEouAsrManager` are Sendable (decides `@retroactive @unchecked Sendable` in Task 5); (f) the type/ceiling of `eouDebounceMs`.

- [ ] **Step 5: Rewrite the findings block**

Edit the "Task 1 findings" section of this plan with real values. Then walk Tasks 2, 3, 5, 6, 7 and fix every constant/call marked `(Task 1)`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved docs/plans/2026-07-04-parakeet-backend.md
git commit -m "build: add FluidAudio dependency; record Parakeet API findings"
```

---

### Task 2: FabCore — engine kind, descriptor, catalog split

**Files:**
- Modify: `Sources/FabCore/ModelDescriptor.swift`
- Test: `Tests/TranscriptionEngineTests/ModelLayoutTests.swift` (existing catalog tests live here)

**Interfaces:**
- Produces: `TranscriptionEngineKind.parakeet`; `ModelDescriptor.parakeetV3` (`id == "parakeet-tdt-0.6b-v3"`); `ModelCatalog.whisperVariants: [ModelDescriptor]`; `ModelCatalog.all` (= whisperVariants + parakeetV3); `ModelCatalog.descriptor(withID:)` resolving whisper variants + parakeet + appleSpeech.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/TranscriptionEngineTests/ModelLayoutTests.swift`:

```swift
@Test func catalogSplitsWhisperVariantsFromParakeet() {
    #expect(ModelCatalog.whisperVariants == [.whisperLargeV3Turbo, .whisperSmall, .whisperBase])
    #expect(!ModelCatalog.whisperVariants.contains(.parakeetV3))
    #expect(ModelCatalog.all.contains(.parakeetV3))
}

@Test func descriptorLookupCoversAllEngines() {
    #expect(ModelCatalog.descriptor(withID: "parakeet-tdt-0.6b-v3") == .parakeetV3)
    #expect(ModelCatalog.descriptor(withID: "apple-speech") == .appleSpeech)
    #expect(ModelCatalog.descriptor(withID: "base") == .whisperBase)
    #expect(ModelCatalog.descriptor(withID: "nope") == nil)
}

@Test func parakeetEngineKindRoundTrips() {
    #expect(TranscriptionEngineKind(rawValue: "parakeet") == .parakeet)
    #expect(TranscriptionEngineKind.parakeet.displayName == "Parakeet (experimental)")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kal/fabulous && swift test --filter ModelLayoutTests`
Expected: FAIL — `whisperVariants`, `parakeetV3`, `.parakeet` don't exist.

- [ ] **Step 3: Implement**

In `Sources/FabCore/ModelDescriptor.swift`, after the `appleSpeech` descriptor:

```swift
    /// NVIDIA Parakeet via FluidAudio (CoreML). One catalog entry covers
    /// BOTH model sets it needs: TDT 0.6b v3 (batch decode + fallback) and
    /// EOU 120M (streaming). Size is their sum.
    public static let parakeetV3 = ModelDescriptor(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet v3",
        // Task 1 finding: v3 (~461 MB) + EOU 160ms (~214 MB) required files,
        // measured via HuggingFace's tree API (not yet a local download).
        approximateSizeMB: 674
    )
```

Extend the engine enum:

```swift
public enum TranscriptionEngineKind: String, Sendable, Codable, CaseIterable {
    case whisper
    /// Apple SpeechAnalyzer — experimental, macOS 26+ only.
    case appleSpeech = "apple-speech"
    /// Parakeet via FluidAudio — experimental. Streams with the EOU 120M
    /// model; batch/fallback decodes with TDT 0.6b v3.
    case parakeet

    public var displayName: String {
        switch self {
        case .whisper: "Whisper"
        case .appleSpeech: "Apple Speech (experimental)"
        case .parakeet: "Parakeet (experimental)"
        }
    }
}
```

Replace `ModelCatalog`:

```swift
/// The models fabulous offers in the UI, best first.
public enum ModelCatalog {
    /// Whisper model variants — the choice `selectedModelID` ranges over.
    public static let whisperVariants: [ModelDescriptor] = [
        .whisperLargeV3Turbo, .whisperSmall, .whisperBase,
    ]

    /// Everything the Models tab shows (downloadable/deletable on disk).
    /// Apple Speech is absent by design: its assets are OS-managed.
    public static let all: [ModelDescriptor] = whisperVariants + [.parakeetV3]

    public static let recommended: ModelDescriptor = .whisperLargeV3Turbo

    /// Resolves any engine/model ID we ever persist (history rows, menu
    /// stats) — including Apple Speech, which is not in `all`.
    public static func descriptor(withID id: String) -> ModelDescriptor? {
        if id == ModelDescriptor.appleSpeech.id { return .appleSpeech }
        return all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Fix the two call sites the split affects**

`Sources/FabulousApp/AppController.swift:173-175` — `selectedModel` must range over whisper variants only:

```swift
    private var selectedModel: ModelDescriptor {
        ModelCatalog.whisperVariants.first { $0.id == settings.selectedModelID }
            ?? ModelCatalog.recommended
    }
```

`Sources/FabulousApp/AppController.swift:684-688` — `statsSummary`'s appleSpeech special case is now redundant:

```swift
    static func statsSummary(_ stats: LatencyStats, engineID: String) -> String {
        let name = ModelCatalog.descriptor(withID: engineID)?.displayName ?? engineID
```

(keep the rest of the function unchanged).

- [ ] **Step 5: Run the full suite**

Run: `cd /Users/kal/fabulous && swift test`
Expected: PASS. (`refreshModelList` now iterates a Parakeet row that reports not-installed until Task 4 — that is correct behavior, not a break. The existing `ModelLayoutTests` line `#expect(ModelCatalog.all.first == ModelCatalog.recommended)` still passes because whisperVariants lead the array.)

- [ ] **Step 6: Commit**

```bash
git add Sources/FabCore/ModelDescriptor.swift Sources/FabulousApp/AppController.swift Tests/TranscriptionEngineTests/ModelLayoutTests.swift
git commit -m "feat: parakeet engine kind + catalog split with unified descriptor lookup"
```

---

### Task 3: ParakeetLayout — on-disk truth for both model sets

**Files:**
- Create: `Sources/TranscriptionEngine/ParakeetLayout.swift`
- Test: `Tests/TranscriptionEngineTests/ParakeetLayoutTests.swift`

**Interfaces:**
- Produces: `ParakeetLayout.v3Repo: String` / `ParakeetLayout.eouRepo: String` (HuggingFace IDs, reference only), `ParakeetLayout.v3FolderName: String` / `ParakeetLayout.eouFolderName: String` (the on-disk leaf names FluidAudio actually uses — Task 1 finding), `ParakeetLayout.repoRoot(_:downloadBase:) -> URL`, `ParakeetLayout.isInstalled(downloadBase:) -> Bool`, `ParakeetLayout.sizeOnDisk(downloadBase:) -> Int64?`, `ParakeetLayout.delete(downloadBase:) throws`.
- Consumes: nothing new (pure Foundation + FabCore).

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranscriptionEngineTests/ParakeetLayoutTests.swift`:

```swift
import FabCore
import Foundation
import Testing
@testable import TranscriptionEngine

struct ParakeetLayoutTests {
    /// Repo roots follow the same hub-shaped tree as Whisper's:
    /// <base>/models/FluidInference/<folderName>/. `folderName` (not the HF
    /// repo ID) because that's the leaf FluidAudio's own load/download path
    /// derivation requires (Task 1 finding).
    @Test func repoRootMatchesHubShape() {
        let base = URL(fileURLWithPath: "/tmp/x")
        let root = ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: base)
        #expect(root.path == "/tmp/x/models/FluidInference/\(ParakeetLayout.v3FolderName)")
    }

    @Test func notInstalledWhenDirectoriesMissing() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        #expect(ParakeetLayout.isInstalled(downloadBase: base) == false)
    }

    /// Installed = every required component of BOTH repos exists.
    @Test func installedOnlyWhenBothReposComplete() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        for file in ParakeetLayout.v3RequiredComponents {
            let url = ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: base)
                .appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        // v3 alone is not enough:
        #expect(ParakeetLayout.isInstalled(downloadBase: base) == false)

        for file in ParakeetLayout.eouRequiredComponents {
            let url = ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase: base)
                .appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        #expect(ParakeetLayout.isInstalled(downloadBase: base) == true)

        try ParakeetLayout.delete(downloadBase: base)
        #expect(ParakeetLayout.isInstalled(downloadBase: base) == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetLayoutTests`
Expected: FAIL — `ParakeetLayout` doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/TranscriptionEngine/ParakeetLayout.swift`. Repo IDs and component
lists are Task 1 findings (resolved values, not provisional — see the findings
block above for citations):

```swift
import FabCore
import Foundation

/// Where Parakeet's two model sets live on disk and what "installed" means.
/// Sibling of `ModelLayout` (Whisper): same `<base>/models/…` tree, but the
/// leaf directory names are FluidAudio's own `Repo.folderName` values, NOT
/// the HuggingFace repo IDs — `AsrModels.load(from:)`/`download(to:)` and
/// `StreamingEouAsrManager.loadModels` both discard whatever leaf directory
/// name they're given and re-derive it from `folderName` internally (Task 1
/// finding), so our roots must already match that name for the directory
/// FluidAudio actually reads/writes to line up with the one `ParakeetLayout`
/// checks. Flat repo layout: the CoreML bundles sit at the repo root, no
/// per-variant subfolder (the EOU chunk-size tier is baked into the folder
/// name itself). FluidAudio loads FROM these directories; it never manages
/// them.
public enum ParakeetLayout {
    /// HuggingFace repo ID — for reference/logging only; NOT the on-disk
    /// folder name (see `v3FolderName`/`eouFolderName`).
    public static let v3Repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let eouRepo = "FluidInference/parakeet-realtime-eou-120m-coreml/160ms"

    /// `AsrModelVersion.v3.repo.folderName` — the literal leaf directory
    /// FluidAudio's ASR loader/downloader derives and requires.
    public static let v3FolderName = "parakeet-tdt-0.6b-v3"
    /// `Repo.parakeetEou160.folderName` — the literal leaf directory
    /// FluidAudio's EOU streaming loader/downloader derives and requires
    /// (160ms chunk size, our default).
    public static let eouFolderName = "parakeet-eou-streaming/160ms"

    public static let v3RequiredComponents = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]
    public static let eouRequiredComponents = [
        "streaming_encoder.mlmodelc",
        "decoder.mlmodelc",
        "joint_decision.mlmodelc",
        "vocab.json",
    ]

    /// `folderName` is FluidAudio's own directory name (see above), not the
    /// HuggingFace repo ID — pass `v3FolderName`/`eouFolderName` here.
    public static func repoRoot(_ folderName: String, downloadBase: URL) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("FluidInference", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func isInstalled(downloadBase: URL) -> Bool {
        isComplete(folderName: v3FolderName, components: v3RequiredComponents, downloadBase: downloadBase)
            && isComplete(folderName: eouFolderName, components: eouRequiredComponents, downloadBase: downloadBase)
    }

    private static func isComplete(folderName: String, components: [String], downloadBase: URL) -> Bool {
        let root = repoRoot(folderName, downloadBase: downloadBase)
        return components.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// Sum of both repo directories, or nil when neither exists.
    public static func sizeOnDisk(downloadBase: URL) -> Int64? {
        let roots = [v3FolderName, eouFolderName].map { repoRoot($0, downloadBase: downloadBase) }
        var total: Int64 = 0
        var found = false
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            found = true
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return found ? total : nil
    }

    /// Removes both repo directories (missing ones are fine). For the EOU
    /// tree this only removes the `160ms` leaf, not sibling chunk-size
    /// variants (we never install those).
    public static func delete(downloadBase: URL) throws {
        for folderName in [v3FolderName, eouFolderName] {
            let root = repoRoot(folderName, downloadBase: downloadBase)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetLayoutTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetLayout.swift Tests/TranscriptionEngineTests/ParakeetLayoutTests.swift
git commit -m "feat: ParakeetLayout — install/verify/size/delete for both model sets"
```

---

### Task 4: ModelManager routes Parakeet through ParakeetLayout + ParakeetInstaller

**Files:**
- Modify: `Sources/TranscriptionEngine/ModelManager.swift`
- Create: `Sources/TranscriptionEngine/ParakeetInstaller.swift`
- Test: `Tests/TranscriptionEngineTests/ParakeetLayoutTests.swift` (extend)

**Interfaces:**
- Consumes: `ParakeetLayout` (Task 3), `ModelDescriptor.parakeetV3` (Task 2).
- Produces: `ModelManager.isInstalled/sizeOnDisk/delete/download` all work when passed `.parakeetV3`; `ParakeetInstaller.download(to:progress:) async throws` (progress 0…1, may be coarse).

- [ ] **Step 1: Write the failing test**

Append to `ParakeetLayoutTests.swift`:

```swift
    /// ModelManager treats the parakeet descriptor via ParakeetLayout, not
    /// the Whisper suffix-match.
    @Test func modelManagerRoutesParakeetDescriptor() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ModelManager(downloadBase: base)

        #expect(await manager.isInstalled(.parakeetV3) == false)

        for (folderName, components) in [
            (ParakeetLayout.v3FolderName, ParakeetLayout.v3RequiredComponents),
            (ParakeetLayout.eouFolderName, ParakeetLayout.eouRequiredComponents),
        ] {
            for file in components {
                let url = ParakeetLayout.repoRoot(folderName, downloadBase: base)
                    .appendingPathComponent(file)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        #expect(await manager.isInstalled(.parakeetV3) == true)
        #expect(await manager.installedModels().contains(.parakeetV3))
        let size = await manager.sizeOnDisk(.parakeetV3)
        #expect((size ?? 0) > 0)
        try await manager.delete(.parakeetV3)
        #expect(await manager.isInstalled(.parakeetV3) == false)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetLayoutTests`
Expected: FAIL — `isInstalled(.parakeetV3)` suffix-matches the Whisper tree and stays false after install (and `delete` throws `notInstalled`).

- [ ] **Step 3: Implement the ModelManager branches**

In `Sources/TranscriptionEngine/ModelManager.swift`, add a private helper and branch each public method:

```swift
    private func isParakeet(_ model: ModelDescriptor) -> Bool {
        model.id == ModelDescriptor.parakeetV3.id
    }
```

`isInstalled` (replace body):

```swift
    public func isInstalled(_ model: ModelDescriptor) -> Bool {
        if isParakeet(model) {
            return ParakeetLayout.isInstalled(downloadBase: downloadBase)
        }
        guard let folder = ModelLayout.installedFolder(for: model, downloadBase: downloadBase)
        else { return false }
        return ModelLayout.isComplete(folder)
    }
```

`download` (insert at the top of the `do`-less body, before `try FabPaths.ensureDirectoryExists`):

```swift
        if isParakeet(model) {
            try FabPaths.ensureDirectoryExists(downloadBase)
            do {
                try await ParakeetInstaller.download(to: downloadBase, progress: progress)
            } catch {
                throw Self.isOffline(error) ? ManagerError.offline : error
            }
            guard ParakeetLayout.isInstalled(downloadBase: downloadBase) else {
                throw ManagerError.incompleteDownload(model.id)
            }
            progress(1.0)
            return ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: downloadBase)
        }
```

`delete` (insert at top):

```swift
        if isParakeet(model) {
            guard ParakeetLayout.isInstalled(downloadBase: downloadBase) else {
                throw ManagerError.notInstalled
            }
            try ParakeetLayout.delete(downloadBase: downloadBase)
            return
        }
```

`sizeOnDisk` (insert at top):

```swift
        if isParakeet(model) {
            return ParakeetLayout.sizeOnDisk(downloadBase: downloadBase)
        }
```

- [ ] **Step 4: Implement ParakeetInstaller**

Create `Sources/TranscriptionEngine/ParakeetInstaller.swift`. Task 1 verified both
FluidAudio download calls against the checked-out source (custom-destination
download exists for both repos — no taught-location fallback needed):

```swift
import FabCore
import FluidAudio
import Foundation

/// Downloads Parakeet's two model repos into our models tree so
/// `ParakeetLayout` owns install-state and the Models tab shows progress.
/// FluidAudio performs the transfer; we choose the destination.
///
/// Both downloads report real fractional `DownloadUtils.DownloadProgress`
/// (Task 1 finding), scaled into the two-thirds-v3/one-third-EOU split below
/// so the Models-tab bar reflects the (larger) v3 download's actual
/// progress rather than jumping in two coarse steps.
public enum ParakeetInstaller {
    public static func download(
        to downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // v3 (~461 MB) — AsrModels.download(to:) discards the last path
        // component of `to:` and re-derives it from `version.repo.folderName`
        // (Task 1 finding), so `repoRoot` must already end in that folder
        // name for the directory FluidAudio actually writes to match what
        // ParakeetLayout checks.
        try await AsrModels.download(
            to: ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: downloadBase),
            version: .v3,
            progressHandler: { downloadProgress in
                progress(downloadProgress.fractionCompleted * 0.7)
            }
        )
        // EOU 160ms (~214 MB) — no standalone static download-only function
        // exists (Task 1 finding); `StreamingEouAsrManager.loadModels(to:)`
        // downloads AND loads CoreML models we'd have to immediately
        // discard, so call the lower-level `DownloadUtils.downloadRepo`
        // directly instead (also `public`, also used internally by
        // `loadModels(to:)`) against the *parent* of the EOU repo root —
        // it appends `Repo.parakeetEou160.folderName` (`"parakeet-eou-streaming/160ms"`)
        // itself, so passing `.../models/FluidInference` (one
        // `deletingLastPathComponent()` off the v3 root, since
        // `v3FolderName` has no internal slash) reproduces exactly
        // `ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase:)`.
        let fluidInferenceDir = ParakeetLayout
            .repoRoot(ParakeetLayout.v3FolderName, downloadBase: downloadBase)
            .deletingLastPathComponent()
        try await DownloadUtils.downloadRepo(
            .parakeetEou160,
            to: fluidInferenceDir,
            progressHandler: { downloadProgress in
                progress(0.7 + downloadProgress.fractionCompleted * 0.3)
            }
        )
        progress(1.0)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetLayoutTests`
Expected: PASS (the new test never calls `download` — no network in unit tests).

Run: `cd /Users/kal/fabulous && swift test`
Expected: PASS, zero warnings.

- [ ] **Step 6: Commit**

```bash
git add Sources/TranscriptionEngine/ModelManager.swift Sources/TranscriptionEngine/ParakeetInstaller.swift Tests/TranscriptionEngineTests/ParakeetLayoutTests.swift
git commit -m "feat: ModelManager install/verify/delete/download for Parakeet"
```

---

### Task 5: ParakeetBackend — batch transcription

**Files:**
- Create: `Sources/TranscriptionEngine/ParakeetBackend.swift`
- Test: `Tests/TranscriptionEngineTests/ParakeetBackendTests.swift`

**Interfaces:**
- Consumes: `ParakeetLayout` (Task 3), `TranscriptionBackend` protocol, FluidAudio `AsrModels.load(from:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:)`, `AsrManager`, `TdtDecoderState`.
- Produces: `public actor ParakeetBackend: TranscriptionBackend` with `init(modelsDirectory: URL = FabPaths.modelsDirectory)`, `load(model:)`, `transcribe(_:language:onProgress:)`, `unload()`. Task 7 adds the streaming conformance to this same actor.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranscriptionEngineTests/ParakeetBackendTests.swift`:

```swift
import FabCore
import Foundation
import Testing
@testable import TranscriptionEngine

struct ParakeetBackendTests {
    @Test func transcribeWithoutLoadThrowsModelNotLoaded() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let audio = FabCore.AudioBuffer(samples: [0.1, 0.2], sampleRate: 16_000)
        await #expect(throws: TranscriptionError.self) {
            _ = try await backend.transcribe(audio, language: nil)
        }
    }

    @Test func loadRejectsNonParakeetDescriptor() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        await #expect(throws: (any Error).self) {
            try await backend.load(model: .whisperBase)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetBackendTests`
Expected: FAIL — `ParakeetBackend` doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/TranscriptionEngine/ParakeetBackend.swift`:

```swift
import FabCore
import FluidAudio
// Scoped import, NOT `import FluidAudio` alone (Task 1 finding — see
// findings block): FluidAudio ships `public struct FluidAudio {}` as a
// deliberate namespace shim (`FluidAudioSwift.swift:29`, its own comment
// calls out the collision), which shadows `FluidAudio.Language` as "member
// `Language` of struct `FluidAudio`" instead of "the module's `Language`
// type" the moment both `FabCore` and `FluidAudio` are imported in the same
// file — `FluidAudio.Language(...)` fails to compile with "type 'FluidAudio'
// has no member 'Language'". This scoped import brings the module's
// `Language` enum into unqualified scope with the priority needed to
// disambiguate against `FabCore.Language`; empirically verified against a
// real FluidAudio v0.15.4 checkout in a throwaway SwiftPM package.
import enum FluidAudio.Language
import Foundation

/// NVIDIA Parakeet running on CoreML via FluidAudio.
///
/// Batch decode + streaming fallback use TDT 0.6b v3; live streaming
/// (Task 7) uses the separate EOU 120M model. Both model sets are
/// installed by `ParakeetInstaller` under `ParakeetLayout`'s roots;
/// FluidAudio only loads from there.
///
/// FluidAudio declares its own `Language`; always qualify `FabCore.Language`
/// in this file, and refer to FluidAudio's via the unqualified `Language`
/// name brought in by the `import enum FluidAudio.Language` line above (see
/// that comment for why `FluidAudio.Language` itself does not compile).
/// `AsrManager` and `StreamingEouAsrManager` (Task 7) are FluidAudio
/// `actor`s — Sendable by the language, no `@retroactive @unchecked
/// Sendable` workaround needed (Task 1 finding; unlike `WhisperKit`, which
/// is a plain `class`).
public actor ParakeetBackend: TranscriptionBackend {
    private var manager: AsrManager?
    private let modelsDirectory: URL

    public init(modelsDirectory: URL = FabPaths.modelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public func load(model: ModelDescriptor) async throws {
        guard model.id == ModelDescriptor.parakeetV3.id else {
            throw TranscriptionError.modelNotLoaded
        }
        if manager != nil { return }
        // `AsrModels.load(from:)` discards the last path component of
        // `from:` and re-derives it from `version.repo.folderName`
        // internally (Task 1 finding) — `repoRoot` already ends in
        // `v3FolderName` so this lines up with what `ParakeetInstaller`
        // downloaded to.
        let models = try await AsrModels.load(
            from: ParakeetLayout.repoRoot(ParakeetLayout.v3FolderName, downloadBase: modelsDirectory),
            configuration: AsrModels.defaultConfiguration(),
            version: .v3
        )
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        manager = loaded
    }

    public func transcribe(
        _ audio: FabCore.AudioBuffer,
        language: FabCore.Language?,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        guard let manager else { throw TranscriptionError.modelNotLoaded }
        guard audio.sampleRate == 16_000 else {
            throw TranscriptionError.unsupportedSampleRate(audio.sampleRate)
        }
        guard !audio.isEmpty else {
            return Transcript(text: "", audioDuration: 0)
        }
        // No progress polling: v3 decodes at ~190× real time, so even a
        // minute of audio finishes inside one progress-UI repaint.
        // `language: nil` = auto-detect (there is no app language setting).
        //
        // Task 1 finding: every `AsrManager.transcribe` overload requires an
        // externalized `decoderState: inout TdtDecoderState` — there is no
        // zero-argument `transcribe(samples)`. A fresh `TdtDecoderState()`
        // per call is correct here: our batch path is one utterance per
        // call with no cross-utterance decoder state to carry (unlike
        // `ParakeetStreamingSession`, Task 7, which is inherently stateful
        // across chunks but owns its own FluidAudio-internal state instead).
        //
        // FluidAudio declares its own `Language` enum (distinct from
        // `FabCore.Language`, a RawRepresentable string wrapper) — bridge by
        // rawValue; an unrecognized/nil code falls through to FluidAudio's
        // auto-detect (nil), which is also our own "no hint" meaning.
        // Unqualified `Language` here resolves to FluidAudio's type via the
        // file's `import enum FluidAudio.Language` line — `FluidAudio.Language`
        // itself does NOT compile once `FabCore` is also imported (Task 1
        // finding, see the file-top comment).
        var decoderState = try TdtDecoderState()
        let fluidLanguage: Language? = language.flatMap { Language(rawValue: $0.rawValue) }
        let result = try await manager.transcribe(
            audio.samples, decoderState: &decoderState, language: fluidLanguage)
        return Transcript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioDuration: audio.duration
        )
    }

    public func unload() {
        manager = nil
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetBackendTests`
Expected: PASS.

Run: `cd /Users/kal/fabulous && swift build --arch arm64`
Expected: zero warnings — no `@retroactive @unchecked Sendable` needed (Task 1 finding: both FluidAudio manager types are actors).

- [ ] **Step 5: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetBackend.swift Tests/TranscriptionEngineTests/ParakeetBackendTests.swift
git commit -m "feat: ParakeetBackend batch transcription via FluidAudio"
```

---

### Task 6: [Float] → AVAudioPCMBuffer glue

**Files:**
- Create: `Sources/TranscriptionEngine/PCMBufferConversion.swift`
- Test: `Tests/TranscriptionEngineTests/PCMBufferConversionTests.swift`

**Interfaces:**
- Produces: `enum PCMBufferConversion { static func buffer(from samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer? }` — nil for empty input.
- Consumed by: `ParakeetStreamingSession.feed` (Task 7).

- [ ] **Step 1: Write the failing tests**

Create `Tests/TranscriptionEngineTests/PCMBufferConversionTests.swift`:

```swift
import AVFoundation
import Testing
@testable import TranscriptionEngine

struct PCMBufferConversionTests {
    @Test func emptyInputReturnsNil() {
        #expect(PCMBufferConversion.buffer(from: []) == nil)
    }

    @Test func samplesRoundTrip() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
        let buffer = try #require(PCMBufferConversion.buffer(from: samples))
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        let data = try #require(buffer.floatChannelData)
        for (index, sample) in samples.enumerated() {
            #expect(data[0][index] == sample)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/kal/fabulous && swift test --filter PCMBufferConversionTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/TranscriptionEngine/PCMBufferConversion.swift`:

```swift
import AVFoundation

/// Wraps raw 16 kHz mono Float32 samples (our capture format) in the
/// `AVAudioPCMBuffer` FluidAudio's streaming API consumes.
enum PCMBufferConversion {
    static func buffer(from samples: [Float], sampleRate: Double = 16_000) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
```

- [ ] **Step 4: Run tests, then commit**

Run: `cd /Users/kal/fabulous && swift test --filter PCMBufferConversionTests`
Expected: PASS.

```bash
git add Sources/TranscriptionEngine/PCMBufferConversion.swift Tests/TranscriptionEngineTests/PCMBufferConversionTests.swift
git commit -m "feat: Float-array to AVAudioPCMBuffer conversion for streaming feeds"
```

---

### Task 7: ParakeetStreamingSession + StreamingTranscriptionBackend conformance

**Files:**
- Modify: `Sources/TranscriptionEngine/ParakeetBackend.swift`
- Create: `Sources/TranscriptionEngine/ParakeetStreamingSession.swift`

**Interfaces:**
- Consumes: `PCMBufferConversion` (Task 6), FluidAudio `StreamingEouAsrManager`, `StreamingSession`/`StreamingTranscriptionBackend` protocols (`Sources/TranscriptionEngine/StreamingTranscription.swift`).
- Produces: `ParakeetBackend: StreamingTranscriptionBackend` with `startStreamingSession() async throws -> any StreamingSession`. Session contract (already defined by the protocol): `feed` ignores post-finish calls; `partials` is a single-consumer AsyncStream of fresh full strings; `finish` returns the final `Transcript`; `cancel` abandons.

- [ ] **Step 1: Implement the session**

No unit test drives this step directly (the manager needs real models); the conditional real-engine test in Task 10 covers it, and `Tests/PipelineTests` already pins the protocol contract with a fake. Create `Sources/TranscriptionEngine/ParakeetStreamingSession.swift`:

```swift
import FabCore
import FluidAudio
import Foundation

/// One utterance streamed through FluidAudio's `StreamingEouAsrManager`
/// (Parakeet EOU 120M — deliberately a smaller model than the batch path's
/// TDT v3; see docs/specs/parakeet-backend.md).
///
/// End-of-utterance auto-detection is FluidAudio's feature, not ours: the
/// hotkey release decides when the utterance ends, so the EOU callback is
/// never registered and the debounce is set high enough (backend init) to
/// never fire mid-dictation.
actor ParakeetStreamingSession: StreamingSession {
    nonisolated let partials: AsyncStream<String>
    private let partialsContinuation: AsyncStream<String>.Continuation
    private let manager: StreamingEouAsrManager
    private var ended = false

    init(manager: StreamingEouAsrManager) async {
        self.manager = manager
        (partials, partialsContinuation) = AsyncStream.makeStream()
        let continuation = partialsContinuation
        await manager.setPartialCallback { partial in
            continuation.yield(partial)
        }
    }

    func feed(_ samples: [Float]) async {
        guard !ended, let buffer = PCMBufferConversion.buffer(from: samples) else { return }
        // A failed chunk is not fatal: the batch fallback still has the
        // full recording. Log-and-continue matches the seam's contract.
        do {
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            NSLog("fabulous: parakeet streaming feed failed (\(error))")
        }
    }

    func finish() async throws -> Transcript {
        guard !ended else { return Transcript(text: "", audioDuration: nil) }
        ended = true
        defer { partialsContinuation.finish() }
        do {
            let text = try await manager.finish()
            await manager.reset()
            return Transcript(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                audioDuration: nil
            )
        } catch {
            await manager.reset()
            throw error
        }
    }

    func cancel() async {
        guard !ended else { return }
        ended = true
        partialsContinuation.finish()
        await manager.reset()
    }
}
```

- [ ] **Step 2: Extend ParakeetBackend**

In `Sources/TranscriptionEngine/ParakeetBackend.swift` change the declaration to

```swift
public actor ParakeetBackend: StreamingTranscriptionBackend {
```

add a stored property next to `manager`:

```swift
    /// The streaming (EOU 120M) engine, loaded once alongside the batch
    /// models and reset between utterances. One session at a time.
    private var streamingManager: StreamingEouAsrManager?
```

extend `load(model:)` — after `manager = loaded`:

```swift
        // Load the streaming model set too; a failure here degrades to
        // batch-only Parakeet (sessions just won't open) instead of failing
        // the whole engine.
        do {
            // Task 1 finding: `eouDebounceMs` is a plain `Int`, default
            // 1280, no compiled ceiling — 600_000 (10 min) is safely usable
            // and never fires mid-dictation; the hotkey ends utterances, not
            // silence detection. `loadModels(from:)` (Task 1 finding) loads
            // flat files directly from the given directory (no folderName
            // re-derivation, unlike the v3 ASR path) — it must directly
            // contain `streaming_encoder.mlmodelc`, `decoder.mlmodelc`,
            // `joint_decision.mlmodelc`, `vocab.json`, which is exactly what
            // `ParakeetLayout.repoRoot(eouFolderName, downloadBase:)` +
            // `ParakeetInstaller`'s `DownloadUtils.downloadRepo` produce.
            let streaming = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 600_000)
            try await streaming.loadModels(
                from: ParakeetLayout.repoRoot(ParakeetLayout.eouFolderName, downloadBase: modelsDirectory)
            )
            streamingManager = streaming
        } catch {
            NSLog("fabulous: parakeet streaming models unavailable, batch-only (\(error))")
            streamingManager = nil
        }
```

add the conformance method and update `unload`:

```swift
    public func startStreamingSession() async throws -> any StreamingSession {
        guard let streamingManager else { throw TranscriptionError.modelNotLoaded }
        return await ParakeetStreamingSession(manager: streamingManager)
    }

    public func unload() {
        manager = nil
        streamingManager = nil
    }
```

- [ ] **Step 3: Build + full test suite**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: builds with zero warnings, all tests pass. Fix any FluidAudio API drift against Task 1 findings (init labels, `loadModels(from:)` spelling) now.

- [ ] **Step 4: Commit**

```bash
git add Sources/TranscriptionEngine/ParakeetBackend.swift Sources/TranscriptionEngine/ParakeetStreamingSession.swift
git commit -m "feat: Parakeet streaming session (EOU 120M) behind the phase-5 seam"
```

---

### Task 8: AppController wiring — load, revert, switch, streaming gate

**Files:**
- Modify: `Sources/FabulousApp/AppController.swift`

**Interfaces:**
- Consumes: `ParakeetBackend` (Tasks 5+7), `ModelManager` parakeet routing (Task 4), `TranscriptionEngineKind.parakeet` (Task 2).
- Produces: selecting the Parakeet engine loads (auto-downloading if needed) with failure-revert to Whisper; Models-tab "Use" on the Parakeet row switches engines; streaming sessions open for any streaming-capable engine.

- [ ] **Step 1: Add the backend instance and route the `backend` property**

At the engines block (`AppController.swift:29-40`), add below `speechAnalyzerBackend`:

```swift
    private let parakeetBackend = ParakeetBackend()
```

and replace the `backend` computed property:

```swift
    /// The backend dictations go through, per the engine preference.
    private var backend: any TranscriptionBackend {
        switch settings.transcriptionEngine {
        case .appleSpeech:
            return speechAnalyzerBackend ?? whisperBackend
        case .parakeet:
            return parakeetBackend
        case .whisper:
            return whisperBackend
        }
    }
```

- [ ] **Step 2: Route engine loading**

`ensureSelectedModelLoaded` (`AppController.swift:177-182`):

```swift
    private func ensureSelectedModelLoaded() async {
        switch settings.transcriptionEngine {
        case .whisper: await loadWhisper()
        case .appleSpeech: await loadAppleSpeech()
        case .parakeet: await loadParakeet()
        }
    }
```

Add `loadParakeet()` after `loadAppleSpeech()` (same revert discipline — the explicit `loadWhisper()` call is what restores dictation, because `onEngineChanged` no-ops outside `.idle`/`.failed`):

```swift
    /// Loads Parakeet, auto-downloading its model sets on first use; any
    /// failure reverts the preference and falls back to Whisper so
    /// dictation keeps working.
    private func loadParakeet() async {
        await whisperBackend.unload()
        if let inactive = speechAnalyzerBackend { await inactive.unload() }
        do {
            if await !modelManager.isInstalled(.parakeetV3) {
                try await downloadModel(.parakeetV3, drivesAppState: true)
            }
            state = .loadingModel(nil)
            try await parakeetBackend.load(model: .parakeetV3)
            activeModelID = ModelDescriptor.parakeetV3.id
            state = .idle
            refreshLatencyStats()
        } catch ModelManager.ManagerError.offline {
            settings.transcriptionEngine = .whisper
            await flashFailure("Offline — can't download Parakeet. Using Whisper")
            await loadWhisper()
        } catch {
            settings.transcriptionEngine = .whisper
            await flashFailure("Parakeet failed (\(shortErrorText(error))) — using Whisper")
            await loadWhisper()
        }
        await refreshModelList()
    }
```

- [ ] **Step 3: Unload Parakeet when other engines take over**

In `loadWhisper()` (`AppController.swift:184`), extend the existing unload line at the top:

```swift
        // Free the inactive engines; keep-warm applies to the active one only.
        if let inactive = speechAnalyzerBackend { await inactive.unload() }
        await parakeetBackend.unload()
```

In `loadAppleSpeech()` after `await whisperBackend.unload()`:

```swift
        await parakeetBackend.unload()
```

In `switchModel(to:)` (`AppController.swift:329`) after the `speechAnalyzerBackend` unload:

```swift
        await parakeetBackend.unload()
```

- [ ] **Step 4: Open streaming sessions by capability, not engine name**

`startStreamingSessionIfAvailable` (`AppController.swift:397-400`) — replace the guard:

```swift
        // Whisper is batch-only, so the cast is the whole engine check.
        guard let streamingBackend = backend as? any StreamingTranscriptionBackend
        else { return }
```

- [ ] **Step 5: Models-tab "Use" on the Parakeet row switches engines**

In `showSettings()` (`AppController.swift:309-311`), replace the `useModel` closure:

```swift
                useModel: { [weak self] model in
                    Task { [weak self] in
                        guard let self else { return }
                        if model.id == ModelDescriptor.parakeetV3.id {
                            guard state == .idle || isFailed(state) else { return }
                            // Fires onEngineChanged, which loads Parakeet.
                            settings.transcriptionEngine = .parakeet
                        } else {
                            await switchModel(to: model)
                        }
                    }
                },
```

- [ ] **Step 6: Build, test, commit**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test`
Expected: zero warnings, all pass.

```bash
git add Sources/FabulousApp/AppController.swift
git commit -m "feat: wire Parakeet engine into AppController (load, revert, switch, streaming gate)"
```

---

### Task 9: Settings UI — un-gate the engine picker, copy updates

**Files:**
- Modify: `Sources/FabulousApp/SettingsView.swift:171-183` (Transcription section), `Sources/FabulousApp/SettingsView.swift:313-317` (Models pane footer)

**Interfaces:**
- Consumes: `TranscriptionEngineKind.parakeet` (Task 2).
- Produces: engine picker always visible; Apple Speech option only on macOS 26+; footer copy names both HF orgs.

- [ ] **Step 1: Replace the gated Transcription section**

The current code wraps the whole section in `if #available(macOS 26.0, *)`. Replace with:

```swift
            Section("Transcription") {
                Picker("Engine", selection: $store.transcriptionEngine) {
                    ForEach(availableEngines, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Whisper models are picked in the Models tab. Apple Speech uses the system's on-device recognizer. Parakeet downloads its models on first use — faster, but experimental.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
```

and add to the same view struct:

```swift
    /// Apple Speech requires the macOS 26 SpeechAnalyzer; the other
    /// engines run on this package's macOS 14 floor.
    private var availableEngines: [TranscriptionEngineKind] {
        TranscriptionEngineKind.allCases.filter { kind in
            guard kind == .appleSpeech else { return true }
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
```

- [ ] **Step 2: Update the Models pane footer**

Replace the footer text (`SettingsView.swift:314`):

```swift
                Text("Models run entirely on this Mac. Downloads come from Hugging Face (argmaxinc/whisperkit-coreml for Whisper, FluidInference for Parakeet) into ~/Library/Application Support/fabulous/models/.")
```

(Task 1 resolved this to our own tree, not FluidAudio's cache — `ParakeetInstaller`
targets `ParakeetLayout`'s roots under our `models/` directory directly, no
taught-location fallback needed. This footer copy is already correct as
written above; no change needed here.)

- [ ] **Step 3: Build + manual GUI check**

Run: `cd /Users/kal/fabulous && swift build --arch arm64 && swift test && scripts/build.sh && open build/fabulous.app`
Manual checklist (record results in the commit message):
- General tab shows three engine options (on macOS 26).
- Models tab shows a "Parakeet v3" row with a Download button.
- Downloading shows progress; when done, "Use" appears; "Use" flips the General-tab radio to Parakeet and the row to Active.
- Dictate once with Parakeet: overlay shows partials, text lands.
- Menu shows a Parakeet p50/p90 line after that dictation.
- Switch back to Whisper: dictation still works (Parakeet unloaded).

- [ ] **Step 4: Commit**

```bash
git add Sources/FabulousApp/SettingsView.swift
git commit -m "feat: engine picker gains Parakeet; section visible below macOS 26"
```

---

### Task 10: Conditional real-engine tests

**Files:**
- Modify: `Tests/TranscriptionEngineTests/ParakeetBackendTests.swift`

**Interfaces:**
- Consumes: everything. Mirrors `Tests/TranscriptionEngineTests/SpeechAnalyzerBackendTests.swift` — copy its `say`-synthesis helper approach (read that file first; reuse its helper if it is reusable, otherwise replicate).

- [ ] **Step 1: Add the gated real-decode tests**

Append to `ParakeetBackendTests.swift` (adjust the audio-synthesis helper to match what `SpeechAnalyzerBackendTests` actually uses — read it first):

```swift
    /// Real-engine tests: FAB_REAL_ASR=1 opts in; additionally auto-skip
    /// unless the Parakeet models are already installed (they are ~1 GB —
    /// tests never download).
    private static var realASREnabled: Bool {
        ProcessInfo.processInfo.environment["FAB_REAL_ASR"] == "1"
            && ParakeetLayout.isInstalled(downloadBase: FabPaths.modelsDirectory)
    }

    @Test(.enabled(if: realASREnabled))
    func batchDecodesSynthesizedSpeech() async throws {
        let backend = ParakeetBackend()
        try await backend.load(model: .parakeetV3)
        let audio = try await SynthesizedAudio.make(text: "hello world this is a test")
        let transcript = try await backend.transcribe(audio, language: nil)
        #expect(transcript.text.lowercased().contains("hello"))
    }

    @Test(.enabled(if: realASREnabled))
    func streamingSessionYieldsPartialsAndFinal() async throws {
        let backend = ParakeetBackend()
        try await backend.load(model: .parakeetV3)
        let session = try await backend.startStreamingSession()
        let audio = try await SynthesizedAudio.make(text: "streaming test one two three")
        // Feed in ~250 ms chunks like the app's feed timer does.
        let chunk = 4_000
        var start = 0
        while start < audio.samples.count {
            let end = min(start + chunk, audio.samples.count)
            await session.feed(Array(audio.samples[start..<end]))
            start = end
        }
        let transcript = try await session.finish()
        #expect(!transcript.text.isEmpty)
    }
```

- [ ] **Step 2: Run without the env var (must skip), then with it**

Run: `cd /Users/kal/fabulous && swift test --filter ParakeetBackendTests`
Expected: the two gated tests report skipped; the Task 5 tests pass.

Then (requires the models installed via the app first):
Run: `cd /Users/kal/fabulous && FAB_REAL_ASR=1 swift test --filter ParakeetBackendTests`
Expected: PASS — real decodes.

- [ ] **Step 3: Commit**

```bash
git add Tests/TranscriptionEngineTests/ParakeetBackendTests.swift
git commit -m "test: conditional real-engine Parakeet decode tests (FAB_REAL_ASR)"
```

---

### Task 11: Docs — CLAUDE.md, architecture, spec status

**Files:**
- Modify: `CLAUDE.md` (Layout bullet for TranscriptionEngine, dependency rule line, Gotchas, State/roadmap)
- Modify: `docs/architecture.md` (backend list)
- Modify: `docs/specs/parakeet-backend.md` (Status line → implemented; record Task 1 findings that differ from the spec's provisional assumptions)

**Interfaces:** none — prose.

- [ ] **Step 1: CLAUDE.md updates**

- Layout, TranscriptionEngine bullet: add `ParakeetBackend` actor + `ParakeetLayout`/`ParakeetInstaller` mention.
- Dependency rule line: change to "`TranscriptionEngine` is the only target importing WhisperKit and FluidAudio."
- Gotchas: add — "**FluidAudio name collisions**: it declares its own `Language` (vs `FabCore.Language`), and it ALSO ships `public struct FluidAudio {}` as a deliberate namespace shim — so `FluidAudio.Language(...)` does NOT compile once both modules are imported in one file (resolves to 'member of struct FluidAudio', not the module). Fix: add `import enum FluidAudio.Language` alongside the plain `import FluidAudio`, then refer to it as bare `Language`; qualify FabCore's side as `FabCore.Language` as usual. **Parakeet streams with a different model**: streaming = EOU 120M, batch/fallback = TDT v3; both install under `models/models/FluidInference/…` via `ParakeetInstaller`, checked by `ParakeetLayout` (NOT `ModelLayout`), and the on-disk leaf directory names are FluidAudio's own `Repo.folderName` values (e.g. `parakeet-tdt-0.6b-v3`, `parakeet-eou-streaming/160ms`) — NOT the HuggingFace repo IDs; FluidAudio's own load/download calls discard whatever leaf name you pass and re-derive it from `folderName`."
- State/roadmap: move Parakeet from "Not yet built" into the done list with one line; note the dogfood decision pending (stay-120M / hybrid / batch-only).

- [ ] **Step 2: architecture.md + spec status**

Add Parakeet to the backend enumeration in `docs/architecture.md`. In `docs/specs/parakeet-backend.md` set `**Status:** implemented <date>` and append a short "As-built notes" section listing every place the Task 1 findings overrode a provisional value.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/architecture.md docs/specs/parakeet-backend.md
git commit -m "docs: Parakeet backend shipped — layout, gotchas, roadmap, as-built notes"
```

---

## Self-review notes (done at plan time)

- **Spec coverage:** engine kind/descriptor (T2), catalog split + unified lookup (T2), layout + install truth (T3), ModelManager routing + downloads (T4), batch backend (T5), PCM glue (T6), streaming session + EOU ignore + debounce (T7), AppController load/revert/unload/capability gate/Use-row (T8), picker un-gating + copy (T9), real-engine tests (T10), docs/gotchas (T11). Offline mapping: T4 reuses `ModelManager.isOffline`. Metrics: engineID flows from `activeModelID` set in T8; menu name resolves via T2's unified lookup. Keep-warm active-engine-only: T8 step 3.
- **Known unknowns are fenced:** every FluidAudio-API assumption is marked `(Task 1)` and Task 1 step 5 forces the sweep before any dependent task runs.
- **Type consistency check:** `ParakeetLayout.repoRoot(_:downloadBase:)` used identically in T3/T4/T5/T7; `ParakeetInstaller.download(to:progress:)` matches T4's call; `PCMBufferConversion.buffer(from:)` matches T7's call; `ParakeetStreamingSession(manager:)` async init matches T7 step 2's call.
