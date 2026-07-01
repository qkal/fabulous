import Foundation

/// A transformation applied to transcribed text before it is injected.
///
/// v1 ships the replacement dictionary and a passthrough. v1.5 adds an
/// LLM-backed cleanup pass (punctuation, filler-word removal) behind this
/// same interface — see docs/architecture.md.
public protocol TextPostProcessor: Sendable {
    func process(_ text: String) async throws -> String
}

/// Does nothing. The default until the user configures replacements.
public struct PassthroughPostProcessor: TextPostProcessor {
    public init() {}

    public func process(_ text: String) async throws -> String {
        text
    }
}

/// Runs a sequence of processors in order.
public struct PostProcessingPipeline: TextPostProcessor {
    public var stages: [any TextPostProcessor]

    public init(stages: [any TextPostProcessor]) {
        self.stages = stages
    }

    public func process(_ text: String) async throws -> String {
        var result = text
        for stage in stages {
            result = try await stage.process(result)
        }
        return result
    }
}
