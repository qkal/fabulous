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
