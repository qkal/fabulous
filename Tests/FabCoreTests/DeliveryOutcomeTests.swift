import FabCore
import Testing

@Suite("DeliveryOutcome")
struct DeliveryOutcomeTests {
    @Test func injectedOutcomeCarriesNoRefusal() {
        let o = DeliveryOutcome(method: .paste, refusal: nil, confirmedSecureField: false)
        #expect(o.method == .paste)
        #expect(o.refusal == nil)
        #expect(o.confirmedSecureField == false)
    }

    @Test func secureFieldOutcomeIsDistinguishable() {
        let o = DeliveryOutcome(method: .safetyNet, refusal: DeliveryRefusal.secureInputActive, confirmedSecureField: true)
        #expect(o.refusal == .secureInputActive)
        #expect(o.confirmedSecureField)
    }
}
