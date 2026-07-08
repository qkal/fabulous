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

    @Test func transcriptionEngineDefaultsToWhisper() {
        let s = SettingsStore(defaults: ephemeral())
        #expect(s.transcriptionEngine == .whisper)
    }

    @Test func screenContextDefaultsOn() {
        let s = SettingsStore(defaults: ephemeral())
        #expect(s.useScreenContext == true)
    }
}
