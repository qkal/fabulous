import Testing
@testable import TextInjector

struct KeystrokeSegmenterTests {
    @Test func plainTextIsOneSegment() {
        #expect(KeystrokeSegmenter.segments(of: "hello") == [.text("hello")])
    }

    @Test func newlineSplitsSegments() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\nb")
                == [.text("a"), .newline, .text("b")]
        )
    }

    @Test func paragraphBreakIsTwoNewlines() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\n\nb")
                == [.text("a"), .newline, .newline, .text("b")]
        )
    }

    @Test func crlfIsOneNewline() {
        #expect(
            KeystrokeSegmenter.segments(of: "a\r\nb")
                == [.text("a"), .newline, .text("b")]
        )
    }

    @Test func leadingAndTrailingNewlines() {
        #expect(
            KeystrokeSegmenter.segments(of: "\na\n")
                == [.newline, .text("a"), .newline]
        )
    }

    @Test func emptyTextIsEmpty() {
        #expect(KeystrokeSegmenter.segments(of: "").isEmpty)
    }
}
