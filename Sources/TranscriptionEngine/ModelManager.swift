import FabCore
import Foundation
import WhisperKit

/// Where WhisperKit's hub client puts model snapshots, and what a complete
/// model folder must contain. Shared by `ModelManager` (install/verify/
/// delete) and `WhisperKitBackend` (load without re-downloading).
public enum ModelLayout {
    public static let repoID = "argmaxinc/whisperkit-coreml"

    /// The hub snapshot root under our download base:
    /// <base>/models/argmaxinc/whisperkit-coreml/
    public static func repoRoot(downloadBase: URL) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repoID, isDirectory: true)
    }

    /// Folder for an installed variant, e.g. "openai_whisper-base".
    /// Matched by suffix so descriptor IDs stay short ("base",
    /// "large-v3_turbo") like WhisperKit's own fuzzy matching.
    public static func installedFolder(for model: ModelDescriptor, downloadBase: URL) -> URL? {
        let root = repoRoot(downloadBase: downloadBase)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        return entries.first { url in
            url.hasDirectoryPath && url.lastPathComponent.hasSuffix(model.id)
        }
    }

    /// The CoreML components a usable model folder must contain.
    public static let requiredComponents = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
    ]

    public static func isComplete(_ folder: URL) -> Bool {
        requiredComponents.allSatisfy { component in
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(component).path
            )
        }
    }
}

/// Downloads, verifies, and deletes models on disk. Loading them into memory
/// is `WhisperKitBackend`'s job.
public actor ModelManager {
    public enum ManagerError: Error, Sendable {
        case offline
        case notInstalled
        case incompleteDownload(String)
    }

    private let downloadBase: URL

    public init(downloadBase: URL = FabPaths.modelsDirectory) {
        self.downloadBase = downloadBase
    }

    private func isParakeet(_ model: ModelDescriptor) -> Bool {
        model.id == ModelDescriptor.parakeetV3.id
    }

    /// A model counts as installed only when all CoreML components exist —
    /// a folder alone may be an interrupted download.
    public func isInstalled(_ model: ModelDescriptor) -> Bool {
        if isParakeet(model) {
            return ParakeetLayout.isInstalled(downloadBase: downloadBase)
        }
        guard let folder = ModelLayout.installedFolder(for: model, downloadBase: downloadBase)
        else { return false }
        return ModelLayout.isComplete(folder)
    }

    public func installedModels() -> [ModelDescriptor] {
        ModelCatalog.all.filter { isInstalled($0) }
    }

    /// Downloads (or resumes/repairs) a model. The hub client skips files
    /// that already exist with the expected size, so calling this on an
    /// installed model re-verifies it against the remote manifest cheaply.
    /// Progress is 0…1.
    @discardableResult
    public func download(
        _ model: ModelDescriptor,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
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
        try FabPaths.ensureDirectoryExists(downloadBase)
        let folder: URL
        do {
            folder = try await WhisperKit.download(
                variant: model.id,
                downloadBase: downloadBase,
                progressCallback: { hubProgress in
                    progress(hubProgress.fractionCompleted)
                }
            )
        } catch {
            throw Self.isOffline(error) ? ManagerError.offline : error
        }
        guard ModelLayout.isComplete(folder) else {
            throw ManagerError.incompleteDownload(folder.lastPathComponent)
        }
        progress(1.0)
        return folder
    }

    public func delete(_ model: ModelDescriptor) throws {
        if isParakeet(model) {
            guard ParakeetLayout.isInstalled(downloadBase: downloadBase) else {
                throw ManagerError.notInstalled
            }
            try ParakeetLayout.delete(downloadBase: downloadBase)
            return
        }
        guard let folder = ModelLayout.installedFolder(for: model, downloadBase: downloadBase)
        else { throw ManagerError.notInstalled }
        try FileManager.default.removeItem(at: folder)
    }

    /// On-disk size of an installed model, or nil.
    public func sizeOnDisk(_ model: ModelDescriptor) -> Int64? {
        if isParakeet(model) {
            return ParakeetLayout.sizeOnDisk(downloadBase: downloadBase)
        }
        guard let folder = ModelLayout.installedFolder(for: model, downloadBase: downloadBase),
              let enumerator = FileManager.default.enumerator(
                  at: folder, includingPropertiesForKeys: [.fileSizeKey]
              )
        else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .timedOut:
            return true
        default:
            return false
        }
    }
}
