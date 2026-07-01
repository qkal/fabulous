import FabCore
import Foundation
import Testing
@testable import TranscriptionEngine

@Suite("ModelLayout & ModelManager (disk only, no network)")
struct ModelLayoutTests {
    /// Creates a fake installed model folder matching the hub layout.
    private func makeFixture(variantFolder: String, complete: Bool) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-models-\(UUID().uuidString)")
        let folder = ModelLayout.repoRoot(downloadBase: base)
            .appendingPathComponent(variantFolder, isDirectory: true)
        let components = complete
            ? ModelLayout.requiredComponents
            : Array(ModelLayout.requiredComponents.dropLast())
        for component in components {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(component),
                withIntermediateDirectories: true
            )
        }
        return base
    }

    @Test func findsInstalledVariantBySuffix() throws {
        let base = try makeFixture(variantFolder: "openai_whisper-base", complete: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = ModelLayout.installedFolder(for: .whisperBase, downloadBase: base)
        #expect(folder?.lastPathComponent == "openai_whisper-base")
    }

    @Test func incompleteFolderIsNotInstalled() async throws {
        let base = try makeFixture(variantFolder: "openai_whisper-base", complete: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ModelManager(downloadBase: base)
        #expect(await manager.isInstalled(.whisperBase) == false)
    }

    @Test func completeFolderIsInstalled() async throws {
        let base = try makeFixture(variantFolder: "openai_whisper-base", complete: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ModelManager(downloadBase: base)
        #expect(await manager.isInstalled(.whisperBase))
        #expect(await manager.installedModels() == [.whisperBase])
    }

    @Test func variantSuffixDoesNotCrossMatch() throws {
        // "base" must not match a hypothetical "...-base_extended" folder,
        // and "large-v3_turbo" must match its own folder exactly.
        let base = try makeFixture(
            variantFolder: "openai_whisper-large-v3_turbo", complete: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ModelLayout.installedFolder(for: .whisperBase, downloadBase: base) == nil)
        #expect(
            ModelLayout.installedFolder(for: .whisperLargeV3Turbo, downloadBase: base) != nil
        )
    }

    @Test func deleteRemovesTheFolder() async throws {
        let base = try makeFixture(variantFolder: "openai_whisper-base", complete: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = ModelManager(downloadBase: base)
        try await manager.delete(.whisperBase)
        #expect(await manager.isInstalled(.whisperBase) == false)
    }

    @Test func deletingUninstalledModelThrows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-empty-\(UUID().uuidString)")
        let manager = ModelManager(downloadBase: base)
        await #expect(throws: ModelManager.ManagerError.self) {
            try await manager.delete(.whisperBase)
        }
    }

    @Test func offlineErrorsAreClassified() {
        #expect(ModelManager.isOffline(URLError(.notConnectedToInternet)))
        #expect(ModelManager.isOffline(URLError(.dnsLookupFailed)))
        #expect(!ModelManager.isOffline(URLError(.badServerResponse)))
        #expect(!ModelManager.isOffline(CocoaError(.fileNoSuchFile)))
    }

    @Test func catalogLooksSane() {
        #expect(ModelCatalog.all.first == ModelCatalog.recommended)
        #expect(ModelCatalog.descriptor(withID: "base") == .whisperBase)
        #expect(ModelCatalog.descriptor(withID: "nope") == nil)
    }
}
