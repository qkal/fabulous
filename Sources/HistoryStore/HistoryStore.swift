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
}
