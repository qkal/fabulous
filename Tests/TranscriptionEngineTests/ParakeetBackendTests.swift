import FabCore
import Foundation
import Testing
@testable import TranscriptionEngine

struct ParakeetBackendTests {
    @Test func transcribeWithoutLoadThrowsModelNotLoaded() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let audio = FabCore.AudioBuffer(samples: [0.1, 0.2], sampleRate: 16_000)
        await #expect(throws: TranscriptionError.self) {
            _ = try await backend.transcribe(audio, language: nil)
        }
    }

    @Test func loadRejectsNonParakeetDescriptor() async {
        let backend = ParakeetBackend(
            modelsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        await #expect(throws: (any Error).self) {
            try await backend.load(model: .whisperBase)
        }
    }
}
