import CoreAudio
import Foundation

struct AudioControl: Codable, Equatable {
    let selector: UInt32
    let element: UInt32
    let original: Float
}

struct MicrophoneSnapshot: Codable {
    let uid: String
    let name: String
    let channelCount: UInt32
    let controls: [AudioControl]
    let muteSelector: UInt32
    let muteElements: [UInt32]
    var talkVolume: Float
}

protocol AudioHardwareAccess {
    func defaultInput() throws -> AudioDeviceID
    func inputDevices() throws -> [AudioDeviceID]
    func string(_ device: AudioDeviceID, selector: UInt32) throws -> String
    func channelCount(_ device: AudioDeviceID) throws -> UInt32
    func isWritable(_ device: AudioDeviceID, selector: UInt32, element: UInt32) -> Bool
    func read(_ device: AudioDeviceID, selector: UInt32, element: UInt32) throws -> Float
    func write(_ device: AudioDeviceID, selector: UInt32, element: UInt32, value: Float) throws
}

struct CoreAudioHardware: AudioHardwareAccess {
    private func address(_ selector: UInt32, element: UInt32 = 0, input: Bool = true) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioObjectPropertyScopeGlobal,
            mElement: element)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AppError("\(operation) failed (Core Audio \(status)).") }
    }

    func defaultInput() throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyDefaultInputDevice, input: false)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device), "Reading the default microphone")
        guard device != kAudioObjectUnknown else { throw AppError("No default microphone is available.") }
        return device
    }

    func inputDevices() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices, input: false)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size), "Listing audio devices")
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try devices.withUnsafeMutableBytes { buffer in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, buffer.baseAddress!), "Listing audio devices")
        }
        return devices.filter { (try? channelCount($0)) ?? 0 > 0 }
    }

    func string(_ device: AudioDeviceID, selector: UInt32) throws -> String {
        var property = address(selector, input: false)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "Reading the microphone name")
        guard let value else { throw AppError("The microphone returned an empty name.") }
        return value.takeRetainedValue() as String
    }

    func channelCount(_ device: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Reading input channels")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage), "Reading input channels")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + $1.mNumberChannels }
    }

    func isWritable(_ device: AudioDeviceID, selector: UInt32, element: UInt32) -> Bool {
        var property = address(selector, element: element)
        var writable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &property)
            && AudioObjectIsPropertySettable(device, &property, &writable) == noErr && writable.boolValue
    }

    func read(_ device: AudioDeviceID, selector: UInt32, element: UInt32) throws -> Float {
        var property = address(selector, element: element)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if selector == kAudioDevicePropertyMute {
            var value: UInt32 = 0
            try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "Reading microphone mute")
            return Float(value)
        }
        var value: Float32 = 0
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value), "Reading microphone volume")
        return value
    }

    func write(_ device: AudioDeviceID, selector: UInt32, element: UInt32, value: Float) throws {
        var property = address(selector, element: element)
        let size = UInt32(MemoryLayout<UInt32>.size)
        if selector == kAudioDevicePropertyMute {
            var mute: UInt32 = value > 0 ? 1 : 0
            try check(AudioObjectSetPropertyData(device, &property, 0, nil, size, &mute), "Setting microphone mute")
        } else {
            var volume = value
            try check(AudioObjectSetPropertyData(device, &property, 0, nil, size, &volume), "Setting microphone volume")
        }
    }
}
