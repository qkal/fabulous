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
            ]
        ),

        // Strategy chain for inserting text into the frontmost app.
        .target(name: "TextInjector", dependencies: ["FabCore"]),

        // Local transcript history (SQLite via GRDB), fully optional at runtime.
        .target(
            name: "HistoryStore",
            dependencies: [
                "FabCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

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
            ]
        ),

        .testTarget(name: "FabCoreTests", dependencies: ["FabCore"]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
        .testTarget(name: "TextInjectorTests", dependencies: ["TextInjector"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "HistoryStoreTests", dependencies: ["HistoryStore"]),
        .testTarget(name: "TranscriptionEngineTests", dependencies: ["TranscriptionEngine"]),
    ]
)
