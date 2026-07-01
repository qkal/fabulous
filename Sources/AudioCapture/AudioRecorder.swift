import AVFoundation
import FabCore
import Foundation

/// Records from the default input device and produces 16 kHz mono Float32
/// audio with leading/trailing silence trimmed.
///
/// All engine state is confined to this actor. The only code that runs off
/// the actor is the render tap, which talks exclusively to `TapProcessor`.
public actor AudioRecorder {
    public enum RecorderError: Error, Sendable {
        case alreadyRecording
        case noInputDevice
        case engineStartFailed(String)
    }

    public static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var tapProcessor: TapProcessor?
    private var configChangeObserver: (any NSObjectProtocol)?
    private let vad: EnergyVAD

    public private(set) var isRecording = false

    public init(vad: EnergyVAD = EnergyVAD()) {
        self.vad = vad
    }

    /// Starts capturing. `deviceUID` selects a specific input device; nil
    /// (or a device that's no longer connected) uses the system default.
    public func start(deviceUID: String? = nil) throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        applyInputDevice(uid: deviceUID)
        let processor = TapProcessor(targetSampleRate: Self.targetSampleRate)
        tapProcessor = processor
        do {
            try installTapAndStart(processor: processor)
        } catch {
            tapProcessor = nil
            throw error
        }
        isRecording = true

        // AirPods connecting (or any default-device change) mid-session posts
        // a configuration change; the engine stops and must be rebuilt.
        // TapProcessor rebuilds its converter on format change, so samples
        // captured before and after the swap stay continuous.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }
    }

    /// Stops capturing and returns the recorded audio, silence-trimmed.
    /// Returns an empty buffer if nothing above the VAD threshold was heard.
    /// (Qualified name: CoreAudio declares an unrelated `AudioBuffer`.)
    public func stop() -> FabCore.AudioBuffer {
        guard isRecording else {
            return FabCore.AudioBuffer(samples: [], sampleRate: Self.targetSampleRate)
        }
        removeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        var raw = tapProcessor?.drain() ?? []
        tapProcessor = nil
        let trimmed = vad.trimSilence(raw, sampleRate: Self.targetSampleRate)
        // Zero the untrimmed copy; the caller owns (and zeroes) the trimmed one.
        for i in raw.indices { raw[i] = 0 }
        return FabCore.AudioBuffer(samples: trimmed, sampleRate: Self.targetSampleRate)
    }

    /// Input level of the most recent buffer (0…1-ish RMS), for a level meter.
    public var currentLevel: Float {
        tapProcessor?.level ?? 0
    }

    /// Points the input node's underlying AudioUnit at the requested device.
    /// Must run before the tap is installed / the engine starts. Failure
    /// (device unplugged since it was picked) silently keeps the default.
    private func applyInputDevice(uid: String?) {
        guard let uid,
              var deviceID = AudioDevices.deviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit
        else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("fabulous: falling back to default input (device select err \(status))")
        }
    }

    private func installTapAndStart(processor: TapProcessor) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            processor.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
    }

    private func handleConfigurationChange() {
        guard isRecording, let processor = tapProcessor else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Re-tap with the new device's format; keep whatever was captured.
        try? installTapAndStart(processor: processor)
    }

    private func removeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }
}
