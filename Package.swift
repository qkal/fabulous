// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fabulous",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "fabulous", targets: ["FabulousApp"])
    ],
    dependencies: [
        // WhisperKit: Whisper models compiled to CoreML, running on ANE/GPU.
        // Vendors its own Hugging Face hub client and tokenizers.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        // GRDB: SQLite for the local transcript history. Chosen over raw
        // sqlite3 for migrations + record types; no server, no ORM magic.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // FluidAudio: Parakeet (TDT v3 batch, EOU 120M streaming) compiled
        // to CoreML. Used for model loading + decode only; downloads and
        // install management stay ours (ParakeetLayout/ModelManager).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        // Shared value types (AudioBuffer, Transcript, ModelDescriptor, …)
        // and the TextPostProcessor pipeline. No AppKit, no side effects.
        .target(name: "FabCore"),

        // AVAudioEngine input tap, 16 kHz mono resampling, energy VAD.
        .target(name: "AudioCapture", dependencies: ["FabCore"]),

        // Global hotkey via CGEventTap with NSEvent global-monitor fallback.
        .target(name: "HotkeyEngine", dependencies: ["FabCore"]),

        // TranscriptionBackend protocol + WhisperKit backend.
        .target(
            name: "TranscriptionEngine",
            dependencies: [
                "FabCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Strategy chain for inserting text into the frontmost app.
        .target(name: "TextInjector", dependencies: ["FabCore"]),

        // Frontmost-window text harvesting via the Accessibility API —
        // uses the Accessibility grant we already hold (no Screen
        // Recording, no screenshots). Feeds ScreenContext to dictation.
        .target(name: "ScreenReader", dependencies: ["FabCore"]),

        // Local transcript history (SQLite via GRDB), fully optional at runtime.
        .target(
            name: "HistoryStore",
            dependencies: [
                "FabCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // On-device LLM transcript cleanup (Apple Foundation Models,
        // macOS 26). The only target importing FoundationModels.
        .target(name: "PostProcessing", dependencies: ["FabCore"]),

        // The menu bar app that wires everything together.
        .executableTarget(
            name: "FabulousApp",
            dependencies: [
                "FabCore",
                "AudioCapture",
                "HotkeyEngine",
                "TranscriptionEngine",
                "TextInjector",
                "HistoryStore",
                "PostProcessing",
                "ScreenReader",
            ]
        ),

        .testTarget(name: "FabCoreTests", dependencies: ["FabCore"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "TextInjectorTests", dependencies: ["TextInjector", "FabCore"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "HistoryStoreTests", dependencies: ["HistoryStore"]),
        .testTarget(name: "TranscriptionEngineTests", dependencies: ["TranscriptionEngine"]),
        .testTarget(name: "PostProcessingTests", dependencies: ["PostProcessing"]),
        .testTarget(name: "ScreenReaderTests", dependencies: ["ScreenReader", "FabCore"]),

        // Cross-module pipeline test: resample → trim → transcribe (fake)
        // → post-process → injection strategy. The only place the stage
        // contracts are exercised together outside the app itself.
        .testTarget(
            name: "PipelineTests",
            dependencies: [
                "FabCore", "AudioCapture", "TranscriptionEngine", "TextInjector",
                "ScreenReader", "PostProcessing",
            ]
        ),

        // Coverage for what's reachable in FabulousApp without a structural
        // seam: SettingsStore defaults and the Silero digest table.
        .testTarget(name: "FabulousAppTests", dependencies: ["FabulousApp"]),
    ]
)
