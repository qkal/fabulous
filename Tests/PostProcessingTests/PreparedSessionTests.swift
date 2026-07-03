@testable import PostProcessing
import Testing

@Suite("PreparedSession")
struct PreparedSessionTests {
    @Test func matchingTakeReturnsSessionOnce() {
        var box = PreparedSession<Int>()
        box.store(7, instructions: "abc")
        #expect(box.take(matching: "abc") == 7)
        // Consumed: a prepared session serves at most one dictation.
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func mismatchedTakeReturnsNilAndDiscards() {
        var box = PreparedSession<Int>()
        box.store(7, instructions: "abc")
        // Focus change / vocab edit between record-start and stop → stale.
        #expect(box.take(matching: "different") == nil)
        // The stale session is gone, not resurrected for a later match.
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func emptyTakeReturnsNil() {
        var box = PreparedSession<Int>()
        #expect(box.take(matching: "abc") == nil)
    }

    @Test func storeReplacesPrevious() {
        var box = PreparedSession<Int>()
        box.store(1, instructions: "old")
        box.store(2, instructions: "new")
        #expect(box.take(matching: "old") == nil)
    }
}
