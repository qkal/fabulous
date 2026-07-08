import CryptoKit
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

    // Pinned to an immutable commit so the digests below match the served bytes.
    private static let pinnedRevision = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
    private static let repoBase =
        "https://huggingface.co/FluidInference/silero-vad-coreml/resolve/\(pinnedRevision)/silero_vad.mlmodelc/"

    /// SHA-256 of each component at `pinnedRevision`. A deliberate model bump
    /// updates both this table and pinnedRevision together.
    static let expectedDigests: [String: String] = [
        "coremldata.bin": "ca7f6a0ab7a349477fed1864e6cf7cb6adf611f017c0c5f0218c694d25e1434a",
        "metadata.json": "eb61c32ad989d6a723672104f1fa3c1a85fe9914f610153361ba1128d8ea0ebe",
        "model.mil": "2d82e44f452039accca85910fe0aa9c7674b12687167a789110b388c06891d62",
        "weights/weight.bin": "45846d0738d3bf5e4b6e9e7d2fddda7b1ad07da33d473f0405e51d3b6c4c11a9",
        "analytics/coremldata.bin": "35c6d0bd3f8dd431fed72221005853ffe3621af1b550951093c41d0b918d210e",
    ]

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
            let data = try Data(contentsOf: temporary)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.expectedDigests[component] else {
                try? FileManager.default.removeItem(at: temporary)
                throw URLError(.cannotDecodeContentData)
            }
            try FabPaths.ensureDirectoryExists(destination.deletingLastPathComponent())
            // Replace, don't fail, if a racing install got there first.
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
        return modelDirectory
    }
}
