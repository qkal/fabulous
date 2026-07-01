import Foundation
import HistoryStore
import Testing

@Suite("HistoryStore")
struct HistoryStoreTests {
    @Test func recordAndFetchNewestFirst() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try store.record(text: "first", audioSeconds: 1, modelID: "base", cap: 10, date: base)
        try store.record(
            text: "second", audioSeconds: 2, modelID: "base", cap: 10,
            date: base.addingTimeInterval(60)
        )

        let recent = try store.recent(limit: 10)
        #expect(recent.map(\.text) == ["second", "first"])
        #expect(recent[0].audioSeconds == 2)
        #expect(recent[0].modelID == "base")
    }

    @Test func capPrunesOldestEntries() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<8 {
            try store.record(
                text: "entry \(i)", audioSeconds: 1, modelID: "base", cap: 5,
                date: base.addingTimeInterval(Double(i))
            )
        }
        #expect(try store.count() == 5)
        let texts = try store.recent(limit: 10).map(\.text)
        #expect(texts == ["entry 7", "entry 6", "entry 5", "entry 4", "entry 3"])
    }

    @Test func clearEmptiesTheTable() throws {
        let store = try HistoryStore.inMemory()
        try store.record(text: "x", audioSeconds: 1, modelID: "base", cap: 10)
        try store.clear()
        #expect(try store.count() == 0)
        #expect(try store.recent(limit: 10).isEmpty)
    }

    @Test func limitCapsRecentResults() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 {
            try store.record(
                text: "entry \(i)", audioSeconds: 1, modelID: "base", cap: 100,
                date: base.addingTimeInterval(Double(i))
            )
        }
        #expect(try store.recent(limit: 2).count == 2)
    }

    @Test func persistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fabulous-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("history.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try HistoryStore(url: url)
        try store.record(text: "durable", audioSeconds: 1, modelID: "base", cap: 10)

        let reopened = try HistoryStore(url: url)
        #expect(try reopened.recent(limit: 1).first?.text == "durable")
    }
}
