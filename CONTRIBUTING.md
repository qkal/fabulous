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
