import Foundation
import CryptoKit

/// TOFU integrity manifest for a model tree: catches corruption and naive
/// modification. NOT a tamper-proof boundary (an attacker who can write the
/// model files can rewrite this sidecar) and does not authenticate upstream.
public struct ModelManifest: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var sha256: String
        public var size: Int
        public var mtime: Double

        public init(sha256: String, size: Int, mtime: Double) {
            self.sha256 = sha256
            self.size = size
            self.mtime = mtime
        }
    }
    public var entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }
}

public enum ModelManifestStore {
    static let filename = ".fab-manifest.json"

    private static func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func meta(_ url: URL) -> (size: Int, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let mdate = attrs[.modificationDate] as? Date
        else { return nil }
        return (size, mdate.timeIntervalSince1970)
    }

    public static func write(root: URL, relativeComponents: [String]) throws {
        var entries: [String: ModelManifest.Entry] = [:]
        for comp in relativeComponents {
            let url = root.appendingPathComponent(comp)
            guard let m = meta(url) else { continue }
            entries[comp] = .init(sha256: try sha256(url), size: m.size, mtime: m.mtime)
        }
        let manifest = ModelManifest(entries: entries)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(filename))
    }

    /// Verifies the tree against its manifest. Cheap size+mtime precheck first;
    /// a full SHA-256 only when those differ — so an unchanged tree is not
    /// re-hashed on every load.
    public static func verify(root: URL, relativeComponents: [String]) -> Bool {
        let manifestURL = root.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else { return false }
        for comp in relativeComponents {
            guard let entry = manifest.entries[comp] else { return false }
            let url = root.appendingPathComponent(comp)
            guard let m = meta(url) else { return false }
            if m.size == entry.size, abs(m.mtime - entry.mtime) < 0.001 { continue }  // unchanged
            guard let digest = try? sha256(url), digest == entry.sha256 else { return false }
        }
        return true
    }
}
