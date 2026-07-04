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
        // No progress(1.0) here: ModelManager.download owns the final
        // signal and emits it only after its isInstalled guard passes —
        // same division of labor as the Whisper path.
    }
}
