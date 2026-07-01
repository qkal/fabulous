import Foundation

/// Well-known filesystem locations. Everything fabulous writes lives under
/// ~/Library/Application Support/fabulous/.
public enum FabPaths {
    public static var applicationSupport: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fabulous", isDirectory: true)
    }

    /// Where model files are downloaded to. Never bundled in the app.
    public static var modelsDirectory: URL {
        applicationSupport.appendingPathComponent("models", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectoryExists(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }
}
