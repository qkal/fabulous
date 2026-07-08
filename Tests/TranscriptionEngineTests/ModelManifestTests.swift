import Foundation
import Testing
@testable import TranscriptionEngine

@Suite("ModelManifest")
struct ModelManifestTests {
    /// Two back-to-back writes to the same path are not guaranteed a
    /// distinct mtime at the sub-millisecond tolerance `verify` uses — under
    /// parallel-test CPU contention the OS can report an identical
    /// timestamp for both, which would make a "tampered" fixture pass the
    /// size+mtime precheck by sheer timing luck (the exact same blind spot
    /// documented on `ModelManifest`: same-size, same-mtime changes are
    /// invisible to the precheck). Bump the mtime explicitly so tamper tests
    /// exercise the hash-fallback path deterministically.
    private func forceMTimeForward(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
    }

    private func tempTree() throws -> (URL, [String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fab-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.bin"))
        try Data("world".utf8).write(to: root.appendingPathComponent("sub/b.bin"))
        return (root, ["a.bin", "sub/b.bin"])
    }

    @Test func writeThenVerifyRoundTrips() throws {
        let (root, comps) = try tempTree()
        try ModelManifestStore.write(root: root, relativeComponents: comps)
        #expect(ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    @Test func tamperedFileFailsVerify() throws {
        let (root, comps) = try tempTree()
        try ModelManifestStore.write(root: root, relativeComponents: comps)
        let tampered = root.appendingPathComponent("a.bin")
        try Data("HELLO".utf8).write(to: tampered)  // same length, different bytes+mtime
        try forceMTimeForward(tampered)
        #expect(!ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    @Test func missingManifestFailsVerify() throws {
        let (root, comps) = try tempTree()
        #expect(!ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    // MARK: - Directory (`.mlmodelc` bundle) components
    //
    // `ModelLayout.requiredComponents` / `ParakeetLayout.*RequiredComponents`
    // are `.mlmodelc` bundle DIRECTORIES, not flat files — `Data(contentsOf:)`
    // throws on a directory URL. The flat-file fixtures above never caught
    // that: these fixtures build an actual nested directory component so a
    // regression here fails loudly again.

    private func directoryTree() throws -> (URL, [String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fab-manifest-dir-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("foo.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("weights"), withIntermediateDirectories: true
        )
        try Data("coreml-data".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        try Data("weights-data!".utf8).write(to: bundle.appendingPathComponent("weights/w.bin"))
        return (root, ["foo.mlmodelc"])
    }

    @Test func writeThenVerifyRoundTripsForDirectoryComponent() throws {
        let (root, comps) = try directoryTree()
        try ModelManifestStore.write(root: root, relativeComponents: comps)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".fab-manifest.json").path))
        #expect(ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    @Test func tamperedLeafInDirectoryFailsVerify() throws {
        let (root, comps) = try directoryTree()
        try ModelManifestStore.write(root: root, relativeComponents: comps)
        // Same length, different bytes+mtime — must still be caught by hash,
        // not silently accepted by the size+mtime precheck.
        let tampered = root.appendingPathComponent("foo.mlmodelc/coremldata.bin")
        try Data("TAMPERED!!!".utf8).write(to: tampered)
        try forceMTimeForward(tampered)
        #expect(!ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    @Test func fileAddedToDirectoryAfterWriteStillVerifies() throws {
        let (root, comps) = try directoryTree()
        try ModelManifestStore.write(root: root, relativeComponents: comps)
        // Simulate CoreML on-load specialization dropping a new cache file
        // into the bundle after the manifest was written. Only the leaves
        // recorded at write time are checked, so this must still verify.
        try Data("specialized-cache".utf8).write(
            to: root.appendingPathComponent("foo.mlmodelc/specialization.bin")
        )
        #expect(ModelManifestStore.verify(root: root, relativeComponents: comps))
    }
}
