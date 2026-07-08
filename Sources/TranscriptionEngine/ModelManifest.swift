import Foundation
import CryptoKit

/// TOFU integrity manifest for a model tree: catches truncation and naive
/// modification via a cheap size+mtime precheck that falls back to a full
/// SHA-256 whenever either differs. It will NOT catch a corruption that
/// happens to preserve both the recorded size and mtime (silent same-size,
/// same-mtime bit-rot) — that's outside what this check can see. NOT a
/// tamper-proof boundary (an attacker who can write the model files can
/// rewrite this sidecar) and does not authenticate upstream.
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

    /// Expands a `write`/`verify` component — a path relative to `root` that
    /// may be a regular file OR a directory (e.g. a `.mlmodelc` CoreML
    /// bundle) — to the sorted list of leaf REGULAR FILES it denotes, each
    /// expressed as a path relative to `root`. A file component expands to
    /// itself; a directory component recursively expands to every regular
    /// file beneath it, skipping nested directories and symlinks, because
    /// `Data(contentsOf:)` throws when handed a directory URL. `write` and
    /// `verify` both go through this so they expand the same components the
    /// same way — write↔verify parity depends on it.
    private static func leafFiles(root: URL, relativeComponent: String) -> [String] {
        let fm = FileManager.default
        let componentURL = root.appendingPathComponent(relativeComponent)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: componentURL.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [relativeComponent] }

        guard let enumerator = fm.enumerator(
            at: componentURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }

        let prefix = componentURL.standardizedFileURL.path + "/"
        var leaves: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let suffix = String(path.dropFirst(prefix.count))
            leaves.append(relativeComponent + "/" + suffix)
        }
        return leaves.sorted()
    }

    public static func write(root: URL, relativeComponents: [String]) throws {
        var entries: [String: ModelManifest.Entry] = [:]
        for comp in relativeComponents {
            for leaf in leafFiles(root: root, relativeComponent: comp) {
                let url = root.appendingPathComponent(leaf)
                guard let m = meta(url) else { continue }
                entries[leaf] = .init(sha256: try sha256(url), size: m.size, mtime: m.mtime)
            }
        }
        let manifest = ModelManifest(entries: entries)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(filename))
    }

    /// Verifies the tree against its manifest. Iterates the manifest's own
    /// recorded leaf entries rather than re-expanding `relativeComponents`
    /// (kept in the signature for call-site compatibility, but unused here)
    /// — so files a CoreML component drops in after `write` ran (on-load
    /// specialization caches, for instance) are simply not checked, and
    /// verify won't false-fail after the model's first load. Cheap
    /// size+mtime precheck first; a full SHA-256 only when those differ —
    /// so an unchanged tree is not re-hashed on every load.
    public static func verify(root: URL, relativeComponents: [String]) -> Bool {
        let manifestURL = root.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
              !manifest.entries.isEmpty
        else { return false }
        for (leaf, entry) in manifest.entries {
            let url = root.appendingPathComponent(leaf)
            guard let m = meta(url) else { return false }
            if m.size == entry.size, abs(m.mtime - entry.mtime) < 0.001 { continue }  // unchanged
            guard let digest = try? sha256(url), digest == entry.sha256 else { return false }
        }
        return true
    }
}
