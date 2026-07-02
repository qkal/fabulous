import FabCore
import Foundation

/// Fetches the Silero VAD CoreML model (~1 MB) into Application Support.
///
/// The compiled .mlmodelc is a directory of five files served straight from
/// the FluidInference/silero-vad-coreml Hugging Face repo — small enough
/// that plain URLSession beats dragging the hub client out of WhisperKit.
/// Like ASR models, it is "installed" only when every component exists, so
/// an interrupted download repairs itself on the next launch.
enum SileroVADInstaller {
    static let modelName = "silero_vad.mlmodelc"

    /// Sibling of the ASR models, outside the hub-shaped subtree that
    /// `ModelLayout` owns.
    static var modelDirectory: URL {
        FabPaths.modelsDirectory
            .appendingPathComponent("vad", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    /// Every file of the compiled model bundle; presence of all of them is
    /// the install criterion.
    static let requiredComponents = [
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
        "analytics/coremldata.bin",
    ]

    private static let repoBase =
        "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/main/silero_vad.mlmodelc/"

    static var isInstalled: Bool {
        requiredComponents.allSatisfy { component in
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent(component).path
            )
        }
    }

    /// Downloads any missing components and returns the model directory.
    static func installIfNeeded(session: URLSession = .shared) async throws -> URL {
        for component in requiredComponents {
            let destination = modelDirectory.appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            guard let source = URL(string: repoBase + component) else {
                throw URLError(.badURL)
            }
            let (temporary, response) = try await session.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw URLError(.badServerResponse)
            }
            try FabPaths.ensureDirectoryExists(destination.deletingLastPathComponent())
            // Replace, don't fail, if a racing install got there first.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
        return modelDirectory
    }
}
