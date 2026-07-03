import FoundationModels

/// Settings-friendly wrapper over the system model's availability.
/// Safe to query on any macOS version.
public enum PostProcessingAvailability: Sendable, Equatable {
    case available
    case appleIntelligenceOff
    case modelNotReady
    case unsupported

    public static var current: PostProcessingAvailability {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unsupported
        }
    }

    /// Why the toggle is disabled; nil when it isn't.
    public var explanation: String? {
        switch self {
        case .available:
            nil
        case .appleIntelligenceOff:
            "Requires Apple Intelligence, which is turned off in System Settings."
        case .modelNotReady:
            "The Apple Intelligence model is still downloading. Try again later."
        case .unsupported:
            "Not supported on this Mac."
        }
    }
}
