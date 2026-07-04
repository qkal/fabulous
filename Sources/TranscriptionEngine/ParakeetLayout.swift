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

    /// Removes both repo directories (missing ones are fine).
    public static func delete(downloadBase: URL) throws {
        for folderName in [v3FolderName, eouFolderName] {
            let root = repoRoot(folderName, downloadBase: downloadBase)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            // A folderName with a path separator (the EOU chunk-size tier)
            // leaves its parent behind once the leaf is gone. Remove the
            // parent only when empty — a sibling chunk-size variant, should
            // one ever be installed, survives.
            guard folderName.contains("/") else { continue }
            let parent = root.deletingLastPathComponent()
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               contents.isEmpty {
                try FileManager.default.removeItem(at: parent)
            }
        }
    }
}
