import FabCore
import Foundation
import Testing

@testable import FabulousApp

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {
    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "fab-test-\(UUID().uuidString)")!
    }

    @Test func historyEnabledDefaultsTrue() {
        let s = SettingsStore(defaults: ephemeral())
        #expect(s.historyEnabled == true)
    }

    @Test func transcriptionEngineDefaultsToParakeet() {
        let s = SettingsStore(defaults: ephemeral())
        #expect(s.transcriptionEngine == .parakeet)
    }

    @Test func storedEngineChoiceSurvivesDefaultFlip() {
        let defaults = ephemeral()
        defaults.set(TranscriptionEngineKind.whisper.rawValue, forKey: "transcriptionEngine")
        let s = SettingsStore(defaults: defaults)
        #expect(s.transcriptionEngine == .whisper)
    }

    @Test func screenContextDefaultsOn() {
        let s = SettingsStore(defaults: ephemeral())
        #expect(s.useScreenContext == true)
    }
}
