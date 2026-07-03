import Foundation
import Testing

@testable import HistoryStore

@Suite struct MetricsStreamedTests {
    private func entry(streamed: Bool) -> MetricsEntry {
        MetricsEntry(
            createdAt: Date(),
            engineID: "apple-speech",
            audioSeconds: 2.0,
            stopTrimMs: 20,
            asrMs: 300,
            postMs: 1,
            deliveryMs: 30,
            totalMs: 351,
            streamed: streamed
        )
    }

    @Test func streamedRoundTrips() throws {
        let store = try HistoryStore.inMemory()
        try store.recordMetrics(entry(streamed: true))
        try store.recordMetrics(entry(streamed: false))
        let stats = try store.latencyStats(engineID: "apple-speech")
        #expect(stats?.sampleCount == 2)
    }

    @Test func streamedDefaultsToFalse() {
        let e = MetricsEntry(
            createdAt: Date(), engineID: "x", audioSeconds: 1,
            stopTrimMs: 1, asrMs: 1, postMs: 1, deliveryMs: 1, totalMs: 4
        )
        #expect(e.streamed == false)
    }

    /// Fabricates a pre-v3 database (v1 + v2 migrations already applied,
    /// `dictationMetrics` has no `streamed` column) with one metrics row
    /// written under the old schema, then reopens it with `HistoryStore`
    /// to run the v3 migration. Proves the actual migration requirement:
    /// the old row's `streamed` column lands as false (not just that a
    /// freshly-inserted row into an already-v3 store defaults correctly).
    @Test func v2DatabaseRowDefaultsStreamedToFalseOnReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-migrate-streamed-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        setup.arguments = [
            url.path,
            """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES ('v1-create-transcript');
            INSERT INTO grdb_migrations VALUES ('v2-create-dictation-metrics');
            CREATE TABLE transcript (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              text TEXT NOT NULL,
              createdAt DATETIME NOT NULL,
              audioSeconds DOUBLE NOT NULL,
              modelID TEXT NOT NULL
            );
            CREATE INDEX transcript_on_createdAt ON transcript(createdAt);
            CREATE TABLE dictationMetrics (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              createdAt DATETIME NOT NULL,
              engineID TEXT NOT NULL,
              audioSeconds DOUBLE NOT NULL,
              stopTrimMs DOUBLE NOT NULL,
              asrMs DOUBLE NOT NULL,
              postMs DOUBLE NOT NULL,
              deliveryMs DOUBLE NOT NULL,
              totalMs DOUBLE NOT NULL
            );
            CREATE INDEX dictationMetrics_on_createdAt ON dictationMetrics(createdAt);
            CREATE INDEX dictationMetrics_on_engineID ON dictationMetrics(engineID);
            INSERT INTO dictationMetrics
              (createdAt, engineID, audioSeconds, stopTrimMs, asrMs, postMs, deliveryMs, totalMs)
              VALUES ('2026-07-01 00:00:00.000', 'apple-speech', 2.0, 20, 300, 1, 30, 351);
            """,
        ]
        try setup.run()
        setup.waitUntilExit()
        #expect(setup.terminationStatus == 0)

        // Reopening runs the v3 migration and must default the pre-existing
        // row's `streamed` column to false rather than failing or leaving
        // it NULL/true.
        let store = try HistoryStore(url: url)
        #expect(try store.latencyStats(engineID: "apple-speech")?.sampleCount == 1)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        check.arguments = [url.path, "SELECT streamed FROM dictationMetrics;"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(output?.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }
}
