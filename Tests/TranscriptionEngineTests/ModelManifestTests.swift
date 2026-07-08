import Foundation
import Testing
@testable import TranscriptionEngine

@Suite("ModelManifest")
struct ModelManifestTests {
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
        try Data("HELLO".utf8).write(to: root.appendingPathComponent("a.bin"))  // same length, different bytes+mtime
        #expect(!ModelManifestStore.verify(root: root, relativeComponents: comps))
    }

    @Test func missingManifestFailsVerify() throws {
        let (root, comps) = try tempTree()
        #expect(!ModelManifestStore.verify(root: root, relativeComponents: comps))
    }
}
