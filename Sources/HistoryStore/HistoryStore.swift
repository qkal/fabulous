import Foundation
import GRDB

/// One dictated transcript, as stored locally. Text only — audio is never
/// persisted anywhere.
public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "transcript"

    public var id: Int64?
    public var text: String
    public var createdAt: Date
    public var audioSeconds: Double
    public var modelID: String

    public init(
        id: Int64? = nil,
        text: String,
        createdAt: Date,
        audioSeconds: Double,
        modelID: String
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.audioSeconds = audioSeconds
        self.modelID = modelID
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Per-dictation timing breakdown, persisted so the engine A/B comparison
/// can be made from p50/p90 over real use instead of memory. Numbers only —
/// deliberately no transcript text, so recording is independent of the
/// history toggle and survives "Clear history".
public struct MetricsEntry: Codable, Sendable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "dictationMetrics"

    public var id: Int64?
    public var createdAt: Date
    /// Which engine produced the dictation (`large-v3_turbo`, `apple-speech`, …).
    public var engineID: String
    public var audioSeconds: Double
    public var stopTrimMs: Double
    public var asrMs: Double
    public var postMs: Double
    public var deliveryMs: Double
    public var totalMs: Double
    /// True when the audio was streamed to the engine during recording
    /// (phase 5); keeps p50/p90 comparisons across the change honest.
    public var streamed: Bool

    public init(
        id: Int64? = nil,
        createdAt: Date,
        engineID: String,
        audioSeconds: Double,
        stopTrimMs: Double,
        asrMs: Double,
        postMs: Double,
        deliveryMs: Double,
        totalMs: Double,
        streamed: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.engineID = engineID
        self.audioSeconds = audioSeconds
        self.stopTrimMs = stopTrimMs
        self.asrMs = asrMs
        self.postMs = postMs
        self.deliveryMs = deliveryMs
        self.totalMs = totalMs
        self.streamed = streamed
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Latency percentiles over recent dictations of one engine.
public struct LatencyStats: Sendable, Equatable {
    public var sampleCount: Int
    public var p50TotalMs: Double
    public var p90TotalMs: Double
    public var p50ASRMs: Double
    public var p90ASRMs: Double

    public init(
        sampleCount: Int,
        p50TotalMs: Double,
        p90TotalMs: Double,
        p50ASRMs: Double,
        p90ASRMs: Double
    ) {
        self.sampleCount = sampleCount
        self.p50TotalMs = p50TotalMs
        self.p90TotalMs = p90TotalMs
        self.p50ASRMs = p50ASRMs
        self.p90ASRMs = p90ASRMs
    }
}

/// Local SQLite history of recent transcripts. Entirely optional: when the
/// user disables history, the app simply never calls `record`. GRDB's
/// `DatabaseQueue` serializes access and is Sendable, so this type is a thin
/// stateless wrapper.
public final class HistoryStore: Sendable {
    private let dbQueue: DatabaseQueue

    /// Opens (creating if needed) the history database at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-create-transcript") { db in
            try db.create(table: TranscriptEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("audioSeconds", .double).notNull()
                t.column("modelID", .text).notNull()
            }
        }
        migrator.registerMigration("v2-create-dictation-metrics") { db in
            try db.create(table: MetricsEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("engineID", .text).notNull().indexed()
                t.column("audioSeconds", .double).notNull()
                t.column("stopTrimMs", .double).notNull()
                t.column("asrMs", .double).notNull()
                t.column("postMs", .double).notNull()
                t.column("deliveryMs", .double).notNull()
                t.column("totalMs", .double).notNull()
            }
        }
        migrator.registerMigration("v3-metrics-streamed") { db in
            try db.alter(table: MetricsEntry.databaseTableName) { t in
                t.add(column: "streamed", .boolean).notNull().defaults(to: false)
            }
        }
        return migrator
    }

    /// Inserts an entry and prunes the table down to `cap` newest rows.
    @discardableResult
    public func record(
        text: String,
        audioSeconds: Double,
        modelID: String,
        cap: Int,
        date: Date = Date()
    ) throws -> TranscriptEntry {
        try dbQueue.write { db in
            var entry = TranscriptEntry(
                text: text, createdAt: date, audioSeconds: audioSeconds, modelID: modelID
            )
            try entry.insert(db)
            try db.execute(
                sql: """
                DELETE FROM transcript WHERE id NOT IN
                  (SELECT id FROM transcript ORDER BY createdAt DESC, id DESC LIMIT ?)
                """,
                arguments: [cap]
            )
            return entry
        }
    }

    /// Newest first.
    public func recent(limit: Int = 50) throws -> [TranscriptEntry] {
        try dbQueue.read { db in
            try TranscriptEntry
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in try TranscriptEntry.fetchCount(db) }
    }

    public func clear() throws {
        _ = try dbQueue.write { db in try TranscriptEntry.deleteAll(db) }
    }

    // MARK: - Dictation metrics

    /// Inserts a metrics row and prunes the table down to `cap` newest rows.
    /// The cap only bounds disk growth; at ~60 bytes a row it's generous.
    @discardableResult
    public func recordMetrics(_ entry: MetricsEntry, cap: Int = 5000) throws -> MetricsEntry {
        try dbQueue.write { db in
            var entry = entry
            try entry.insert(db)
            try db.execute(
                sql: """
                DELETE FROM dictationMetrics WHERE id NOT IN
                  (SELECT id FROM dictationMetrics ORDER BY createdAt DESC, id DESC LIMIT ?)
                """,
                arguments: [cap]
            )
            return entry
        }
    }

    /// p50/p90 latency over the newest `limit` dictations of one engine;
    /// nil when that engine has no rows yet.
    public func latencyStats(engineID: String, limit: Int = 500) throws -> LatencyStats? {
        let rows = try dbQueue.read { db in
            try MetricsEntry
                .filter(Column("engineID") == engineID)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        guard !rows.isEmpty else { return nil }
        let totals = rows.map(\.totalMs).sorted()
        let asrs = rows.map(\.asrMs).sorted()
        return LatencyStats(
            sampleCount: rows.count,
            p50TotalMs: Self.percentile(totals, 0.5),
            p90TotalMs: Self.percentile(totals, 0.9),
            p50ASRMs: Self.percentile(asrs, 0.5),
            p90ASRMs: Self.percentile(asrs, 0.9)
        )
    }

    /// Nearest-rank percentile of an already-sorted, non-empty array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
