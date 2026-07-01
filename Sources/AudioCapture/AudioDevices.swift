import CoreAudio
import Foundation

/// An audio input device as shown in the settings picker.
public struct CaptureDevice: Sendable, Equatable, Identifiable {
    /// Core Audio device UID — stable across reboots and reconnects,
    /// which is why it (not the transient AudioDeviceID) is what we persist.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Core Audio HAL queries for input devices. All functions are synchronous
/// and callable from anywhere; the HAL does its own locking.
public enum AudioDevices {
    /// All devices that have at least one input stream, in HAL order.
    public static func inputDevices() -> [CaptureDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInputStreams(deviceID),
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return CaptureDevice(id: uid, name: name)
        }
    }

    /// Resolves a persisted UID back to today's transient device ID.
    /// Returns nil when the device isn't connected right now.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceID in
            hasInputStreams(deviceID)
                && stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    // MARK: - HAL plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        var ids = [AudioDeviceID](
            repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize) == noErr
            && dataSize > 0
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
