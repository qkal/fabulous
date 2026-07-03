import Foundation
import Testing

@testable import FabCore

@Suite struct DeliveryMethodTests {
    /// Raw values are the on-disk schema (dictationMetrics.deliveryMethod).
    @Test func rawValuesArePinned() {
        #expect(DeliveryMethod.axInsert.rawValue == "axInsert")
        #expect(DeliveryMethod.paste.rawValue == "paste")
        #expect(DeliveryMethod.keystrokes.rawValue == "keystrokes")
        #expect(DeliveryMethod.safetyNet.rawValue == "safetyNet")
    }

    private func metrics(deliveryMethod: DeliveryMethod) -> DictationMetrics {
        DictationMetrics(
            audioDuration: 2.0,
            stopAndTrim: .milliseconds(40),
            transcription: .milliseconds(900),
            postProcessing: .milliseconds(5),
            delivery: .milliseconds(60),
            total: .milliseconds(1005),
            deliveryMethod: deliveryMethod
        )
    }

    @Test func logLineNamesTheDeliveryMethod() {
        #expect(metrics(deliveryMethod: .paste).logLine.contains(" via=paste"))
        #expect(metrics(deliveryMethod: .safetyNet).logLine.contains(" via=safetyNet"))
    }
}
