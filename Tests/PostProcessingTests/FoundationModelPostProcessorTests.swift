import FabCore
import Foundation
import PostProcessing
import Testing

/// Scriptable fake model.
private struct FakeRequester: LanguageModelRequesting {
    enum Behavior: Sendable {
        case reply(String)
        case fail
        case hang
    }
    let behavior: Behavior

    func cleanup(instructions: String, transcript: String) async throws -> String {
        switch behavior {
        case let .reply(text): return text
        case .fail: throw CocoaError(.featureUnsupported)
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return transcript
        }
    }
}

struct FoundationModelPostProcessorTests {
    private func processor(
        _ behavior: FakeRequester.Behavior,
        timeout: Duration = .seconds(3)
    ) -> FoundationModelPostProcessor {
        FoundationModelPostProcessor(
            requester: FakeRequester(behavior: behavior),
            vocabulary: [],
            timeout: timeout
        )
    }

    @Test func successReturnsCleanedText() async throws {
        let p = processor(.reply("Ship it."))
        #expect(try await p.process("um ship it") == "Ship it.")
    }

    @Test func edgeSpacesFromModelAreStripped() async throws {
        let p = processor(.reply("  Ship it. "))
        #expect(try await p.process("um ship it") == "Ship it.")
    }

    @Test func edgeNewlinesFromCommandsSurvive() async throws {
        let p = processor(.reply("ship it\n\n"))
        #expect(try await p.process("ship it new paragraph") == "ship it\n\n")
    }

    @Test func modelErrorFallsBackToRawText() async throws {
        let p = processor(.fail)
        #expect(try await p.process("um ship it") == "um ship it")
    }

    @Test func timeoutFallsBackToRawText() async throws {
        let p = processor(.hang, timeout: .milliseconds(50))
        #expect(try await p.process("um ship it") == "um ship it")
    }

    @Test func emptyOutputWithoutCommandFallsBackToRawText() async throws {
        let p = processor(.reply("  \n"))
        #expect(try await p.process("hello world") == "hello world")
    }

    @Test func emptyOutputWithTrailingScratchThatIsAccepted() async throws {
        let p = processor(.reply(""))
        #expect(try await p.process("blah blah scratch that") == "")
    }

    @Test func emptyOutputWithMidUtteranceScratchThatFallsBackToRawText() async throws {
        let p = processor(.reply(""))
        let content = "scratch that section off the list"
        #expect(try await p.process(content) == content)
    }

    @Test func emptyInputSkipsModel() async throws {
        let p = processor(.fail) // would throw if called
        #expect(try await p.process("") == "")
    }

    @Test func scratchThatDetection() {
        #expect(FoundationModelPostProcessor.endsWithScratchThat("blah Scratch That"))
        #expect(FoundationModelPostProcessor.endsWithScratchThat("blah blah, scratch that."))
        #expect(!FoundationModelPostProcessor.endsWithScratchThat("hello world"))
        #expect(!FoundationModelPostProcessor.endsWithScratchThat("scratch that section off the list"))
    }

    // MARK: - CleanupReport outcomes

    @Test func reportChangedWhenModelRewrites() async {
        let p = processor(.reply("Ship it."))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "Ship it.", outcome: .changed))
    }

    @Test func reportUnchangedWhenModelEchoes() async {
        let p = processor(.reply("um ship it"))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .unchanged))
    }

    @Test func reportUnchangedComparesAfterEdgeStrip() async {
        // Model echoed with stray edge spaces: text is stripped, still a no-op.
        let p = processor(.reply("  um ship it "))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .unchanged))
    }

    @Test func reportFellBackOnError() async {
        let p = processor(.fail)
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .fellBack))
    }

    @Test func reportFellBackOnTimeout() async {
        let p = processor(.hang, timeout: .milliseconds(50))
        let report = await p.cleanup("um ship it")
        #expect(report == CleanupReport(text: "um ship it", outcome: .fellBack))
    }

    @Test func reportFellBackOnRejectedEmptyOutput() async {
        let p = processor(.reply("  \n"))
        let report = await p.cleanup("hello world")
        #expect(report == CleanupReport(text: "hello world", outcome: .fellBack))
    }

    @Test func reportChangedOnLegitimateScratchToEmpty() async {
        let p = processor(.reply(""))
        let report = await p.cleanup("blah blah scratch that")
        #expect(report == CleanupReport(text: "", outcome: .changed))
    }

    @Test func reportUnchangedOnEmptyInput() async {
        let p = processor(.fail) // would throw if the model were called
        let report = await p.cleanup("")
        #expect(report == CleanupReport(text: "", outcome: .unchanged))
    }
}
