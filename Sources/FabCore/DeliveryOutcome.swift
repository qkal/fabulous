import Foundation

/// Why a dictation's delivery ended the way it did. FabCore-local mirror of
/// TextInjector's RefusalReason (FabCore can't import TextInjector), mapped at
/// the AppController boundary.
public enum DeliveryRefusal: Sendable, Equatable {
    case secureInputActive
    case accessibilityNotGranted
    case focusChanged
    case allStrategiesFailed
}

/// The full result of delivering one transcript: the persisted DeliveryMethod
/// plus the reason (for non-injection paths) and whether the focused field was
/// an AX-confirmed secure (password) field.
public struct DeliveryOutcome: Sendable, Equatable {
    public let method: DeliveryMethod
    public let refusal: DeliveryRefusal?
    public let confirmedSecureField: Bool

    public init(method: DeliveryMethod, refusal: DeliveryRefusal?, confirmedSecureField: Bool) {
        self.method = method
        self.refusal = refusal
        self.confirmedSecureField = confirmedSecureField
    }
}
