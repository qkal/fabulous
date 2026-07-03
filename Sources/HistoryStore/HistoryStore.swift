import FabCore
import Foundation
import GRDB

/// One dictated transcript, as stored locally. Text only — audio is never
/// persisted anywhere. rawText is the pre-LLM-cleanup transcript; kept only
/// when LLM cleanup changed the transcript, otherwise nil.
public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord
{
    public static let databaseTableName = "transcript"

    public var id: Int64?
    public var text: String
    public var createdAt: Date
    public var audioSeconds: Double
    public var modelID: String
    public var rawText: String?

    public init(
        id: Int64? = nil,
        text: String,
        createdAt: Date,
        audioSeconds: Double,
        modelID: String,
        rawText: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.audioSeconds = audioSeconds
        self.modelID = modelID
        self.rawText = rawText
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
    /// Duration of the transcribed audio. Streamed rows record the raw fed
    /// duration; batch rows record the VAD-trimmed duration — a small
    /// systematic skew to keep in mind when comparing engines by this column.
    public var audioSeconds: Double
    public var stopTrimMs: Double
    public var asrMs: Double
    public var postMs: Double
    public var deliveryMs: Double
    public var totalMs: Double
    /// True when the audio was streamed to the engine during recording
    /// (phase 5); keeps p50/p90 comparisons across the change honest.
    public var streamed: Bool
    /// Wall time of the LLM cleanup stage in milliseconds; 0 when off.
    public var llmMs: Double
    /// What the cleanup stage did; stored as the enum's raw-value text.
    public var llmOutcome: LLMCleanupOutcome

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
        streamed: Bool = false,
        llmMs: Double = 0,
        llmOutcome: LLMCleanupOutcome = .off
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
        self.llmMs = llmMs
        self.llmOutcome = llmOutcome
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

/// LLM cleanup latency/reliability over recent dictations (all engines —
/// the cleanup model is engine-independent).
public struct CleanupStats: Sendable, Equatable {
    public var sampleCount: Int
    public var p50LlmMs: Double
    public var p90LlmMs: Double
    public var fellBackCount: Int

    public init(
        sampleCount: Int, p50LlmMs: Double, p90LlmMs: Double, fellBackCount: Int
    ) {
        self.sampleCount = sampleCount
        self.p50LlmMs = p50LlmMs
        self.p90LlmMs = p90LlmMs
        self.fellBackCount = fellBackCount
    }

    /// e.g. "Cleanup p50 0.38 s · p90 0.71 s · fell back 2/41"
    public var menuSummary: String {
        let p50 = String(format: "%.2f", p50LlmMs / 1000)
        let p90 = String(format: "%.2f", p90LlmMs / 1000)
        return "Cleanup p50 \(p50) s · p90 \(p90) s"
            + " · fell back \(fellBackCount)/\(sampleCount)"
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
        migrator.registerMigration("v4-transcript-rawtext") { db in
            try db.alter(table: TranscriptEntry.databaseTableName) { t in
                // Pre-LLM-cleanup transcript; NULL when cleanup was off
                // or changed nothing.
                t.add(column: "rawText", .text)
            }
        }
        migrator.registerMigration("v5-metrics-llm") { db in
            try db.alter(table: MetricsEntry.databaseTableName) { t in
                t.add(column: "llmMs", .double).notNull().defaults(to: 0)
                t.add(column: "llmOutcome", .text).notNull()
                    .defaults(to: LLMCleanupOutcome.off.rawValue)
            }
        }
        return migrator
    }

    /// Inserts an entry and prunes the table down to `cap` newest rows.
    @discardableResult
    public func record(
        text: String,
        rawText: String? = nil,
        audioSeconds: Double,
        modelID: String,
        cap: Int,
        date: Date = Date()
    ) throws -> TranscriptEntry {
        try dbQueue.write { db in
            var entry = TranscriptEntry(
                text: text, createdAt: date, audioSeconds: audioSeconds, modelID: modelID,
                rawText: rawText
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

    /// Cleanup p50/p90 and fallback count over the newest `limit` dictations
    /// where the LLM stage ran; nil when it never has.
    public func cleanupStats(limit: Int = 500) throws -> CleanupStats? {
        let rows = try dbQueue.read { db in
            try MetricsEntry
                .filter(Column("llmOutcome") != LLMCleanupOutcome.off.rawValue)
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
        guard !rows.isEmpty else { return nil }
        let times = rows.map(\.llmMs).sorted()
        return CleanupStats(
            sampleCount: rows.count,
            p50LlmMs: Self.percentile(times, 0.5),
            p90LlmMs: Self.percentile(times, 0.9),
            fellBackCount: rows.filter { $0.llmOutcome == .fellBack }.count
        )
    }

    /// Raw llmOutcome column values, newest first — pins the on-disk
    /// representation in tests.
    public func rawLLMOutcomes() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT llmOutcome FROM dictationMetrics ORDER BY createdAt DESC, id DESC"
            )
        }
    }

    /// Nearest-rank percentile of an already-sorted, non-empty array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
