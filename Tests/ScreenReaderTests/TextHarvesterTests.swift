import ScreenReader
import Testing

/// In-memory tree standing in for AXUIElements.
struct FakeNode: TextHarvestNode {
    var subrole: String?
    var title: String?
    var textValue: String?
    var children: [FakeNode] = []
}

@Suite struct TextHarvesterTests {
    @Test func collectsTitlesAndValuesDepthFirst() {
        let tree = FakeNode(
            subrole: nil, title: "Window", textValue: nil,
            children: [
                FakeNode(subrole: nil, title: nil, textValue: "hello"),
                FakeNode(subrole: nil, title: "Sidebar", textValue: "world"),
            ]
        )
        #expect(TextHarvester.harvest(tree) == ["Window", "hello", "Sidebar", "world"])
    }

    @Test func skipsSecureFieldSubtree() {
        let tree = FakeNode(
            subrole: nil, title: nil, textValue: "safe",
            children: [
                FakeNode(
                    subrole: "AXSecureTextField", title: nil, textValue: "hunter2",
                    children: [FakeNode(subrole: nil, title: nil, textValue: "nested-secret")]
                ),
                FakeNode(subrole: nil, title: nil, textValue: "also safe"),
            ]
        )
        let pieces = TextHarvester.harvest(tree)
        #expect(pieces == ["safe", "also safe"])
    }

    @Test func depthLimitStopsDescent() {
        var leaf = FakeNode(subrole: nil, title: nil, textValue: "deep")
        for _ in 0..<5 {
            leaf = FakeNode(subrole: nil, title: nil, textValue: nil, children: [leaf])
        }
        #expect(TextHarvester.harvest(leaf, maxDepth: 3).isEmpty)
        #expect(TextHarvester.harvest(leaf, maxDepth: 5) == ["deep"])
    }

    @Test func charCapTruncatesAndStops() {
        let tree = FakeNode(
            subrole: nil, title: nil, textValue: String(repeating: "a", count: 30),
            children: [FakeNode(subrole: nil, title: nil, textValue: "never reached")]
        )
        let pieces = TextHarvester.harvest(tree, charCap: 10)
        #expect(pieces == [String(repeating: "a", count: 10)])
    }

    @Test func nodeCapBoundsPathologicalTrees() {
        let wide = FakeNode(
            subrole: nil, title: nil, textValue: nil,
            children: (0..<100).map { FakeNode(subrole: nil, title: nil, textValue: "n\($0)") }
        )
        // Root consumes 1 slot; 10 children visited after it.
        #expect(TextHarvester.harvest(wide, nodeCap: 11).count == 10)
    }

    @Test func shouldContinueFalseStopsImmediately() {
        let tree = FakeNode(subrole: nil, title: "T", textValue: "v")
        #expect(TextHarvester.harvest(tree, shouldContinue: { false }).isEmpty)
    }
}
