import AVFoundation
import Testing
@testable import TranscriptionEngine

struct PCMBufferConversionTests {
    @Test func emptyInputReturnsNil() {
        #expect(PCMBufferConversion.buffer(from: []) == nil)
    }

    @Test func samplesRoundTrip() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
        let buffer = try #require(PCMBufferConversion.buffer(from: samples))
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        let data = try #require(buffer.floatChannelData)
        for (index, sample) in samples.enumerated() {
            #expect(data[0][index] == sample)
        }
    }
}
