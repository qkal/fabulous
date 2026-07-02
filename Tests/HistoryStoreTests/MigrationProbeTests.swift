import Foundation
import Testing

@testable import HistoryStore

/// Opens a database that only has the v1 migration applied (the state of
/// every install that predates dictation metrics) and proves v2 lands
/// without touching the transcripts.
@Suite struct MigrationProbeTests {
    @Test func v1DatabaseGainsMetricsTableOnReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-migrate-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Fabricate a v1-only database the way GRDB would have left it.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        setup.arguments = [
            url.path,
            """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES ('v1-create-transcript');
            CREATE TABLE transcript (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              text TEXT NOT NULL,
              createdAt DATETIME NOT NULL,
              audioSeconds DOUBLE NOT NULL,
              modelID TEXT NOT NULL
            );
            CREATE INDEX transcript_on_createdAt ON transcript(createdAt);
            INSERT INTO transcript (text, createdAt, audioSeconds, modelID)
              VALUES ('kept', '2026-07-01 00:00:00.000', 3.5, 'large-v3_turbo');
            """,
        ]
        try setup.run()
        setup.waitUntilExit()
        #expect(setup.terminationStatus == 0)

        let store = try HistoryStore(url: url)
        #expect(try store.count() == 1)
        #expect(try store.recent(limit: 1).first?.text == "kept")

        try store.recordMetrics(MetricsEntry(
            createdAt: Date(), engineID: "apple-speech", audioSeconds: 10,
            stopTrimMs: 5, asrMs: 400, postMs: 1, deliveryMs: 30, totalMs: 450
        ))
        #expect(try store.latencyStats(engineID: "apple-speech")?.sampleCount == 1)
    }
}
