import CoreAudio
import Foundation

private final class FakeHardware: AudioHardwareAccess {
    var selected: AudioDeviceID = 1
    var channels: UInt32 = 2
    var values: [AudioDeviceID: [String: Float]] = [:]
    var failElement: UInt32?
    var failMuteDevice: AudioDeviceID?
    var onRead: (() -> Void)?
    var onWrite: ((Float) -> Void)?
    var writes: [(UInt32, UInt32, Float)] = []
    func key(_ selector: UInt32, _ element: UInt32) -> String { "\(selector):\(element)" }
    func defaultInput() throws -> AudioDeviceID { selected }
    func inputDevices() throws -> [AudioDeviceID] { Array(values.keys) }
    func string(_ device: AudioDeviceID, selector: UInt32) throws -> String { "Device \(device)" }
    func channelCount(_ device: AudioDeviceID) throws -> UInt32 { channels }
    func isWritable(_ device: AudioDeviceID, selector: UInt32, element: UInt32) -> Bool {
        values[device]?[key(selector, element)] != nil
    }
    func read(_ device: AudioDeviceID, selector: UInt32, element: UInt32) throws -> Float {
        onRead?()
        guard let value = values[device]?[key(selector, element)] else { throw AppError("Missing control") }
        return value
    }
    func write(_ device: AudioDeviceID, selector: UInt32, element: UInt32, value: Float) throws {
        writes.append((selector, element, value))
        if element == failElement || (device == failMuteDevice && value == 0) { throw AppError("Write refused") }
        values[device, default: [:]][key(selector, element)] = value
        onWrite?(value)
    }
    func add(_ device: AudioDeviceID = 1, selector: UInt32, element: UInt32, value: Float) {
        values[device, default: [:]][key(selector, element)] = value
    }
}

final class MicrophoneTests {
    private var directory: URL!
    private var store: SessionStore!
    private var hardware: FakeHardware!
    private var microphone: Microphone!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SessionStore(url: directory.appendingPathComponent("session.json"))
        hardware = FakeHardware()
        microphone = Microphone(store: store, hardware: hardware)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func testVolumeFallbackMutesAllChannelsAndRestoresOriginalLevels() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 1, value: 0.4)
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 2, value: 0.8)
        try microphone.selectDefault()
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 1) == 0)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 2) == 0)
        try microphone.setTalking(true)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 1) == 0.4)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 2) == 0.8)
        try microphone.setTalking(false)
        try microphone.restoreAll()
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 1) == 0.4)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 2) == 0.8)
        try expect(store.snapshot.microphones.isEmpty)
    }

    func testHardwareMutePreferredAndVolumeSliderWorksWithoutUnmuting() throws {
        hardware.add(selector: kAudioDevicePropertyMute, element: 0, value: 0)
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.5)
        try microphone.selectDefault()
        try expect(microphone.current?.muteSelector == kAudioDevicePropertyMute)
        try microphone.setTalkVolume(0.9)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyMute, element: 0) == 1)
        try microphone.setTalking(true)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0.9)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyMute, element: 0) == 0)
        try microphone.restoreAll()
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0.5)
    }

    func testRejectsPartiallyControllableMicrophone() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 1, value: 0.7)
        try expectThrows { try microphone.selectDefault() }
        try expect(hardware.writes.isEmpty)
    }

    func testMutingContinuesAfterOneChannelFails() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 1, value: 0.7)
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 2, value: 0.7)
        hardware.failElement = 1
        try expectThrows { try microphone.selectDefault() }
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 2) == 0)
    }

    func testIdleReassertsMuteAfterAnotherAppChangesGain() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.7)
        try microphone.selectDefault()
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.9)
        try microphone.setTalking(false)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testDeviceSwitchMutesBothDevicesAndRequiresFreshPress() throws {
        hardware.add(1, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.6)
        hardware.add(2, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.8)
        try microphone.selectDefault()
        try microphone.setTalking(true)
        hardware.selected = 2
        try expect(try microphone.selectDefault())
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
        try expect(try hardware.read(2, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
        try microphone.restoreAll()
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0.6)
        try expect(try hardware.read(2, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0.8)
    }

    func testCrashRecoveryRetainsOriginalVolumeInsteadOfCapturingZero() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.65)
        try microphone.selectDefault()
        let recoveredStore = try SessionStore(url: directory.appendingPathComponent("session.json"))
        let recovered = Microphone(store: recoveredStore, hardware: hardware)
        try recovered.selectDefault()
        try recovered.setTalking(true)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0.65)
    }

    func testInitiallyZeroVolumeGetsUsableTalkLevelButRestoresZeroOnQuit() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0)
        try microphone.selectDefault()
        try microphone.setTalking(true)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) > 0)
        try microphone.restoreAll()
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testUnpluggedMicrophoneDoesNotBlockSwitchToNewInput() throws {
        hardware.add(1, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.6)
        hardware.add(2, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.8)
        try microphone.selectDefault()
        try microphone.setTalking(true)
        hardware.values.removeValue(forKey: 1)
        hardware.selected = 2
        try expect(try microphone.selectDefault())
        try expect(try hardware.read(2, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testOldMuteFailureStillMutesAndRecordsNewInput() throws {
        hardware.add(1, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.6)
        hardware.add(2, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.8)
        try microphone.selectDefault()
        try microphone.setTalking(true)
        hardware.failMuteDevice = 1
        hardware.selected = 2
        try expectThrows { try microphone.selectDefault() }
        microphone.muteAllSaved()
        try expect(try hardware.read(2, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
        try expect(store.snapshot.microphones.count == 2)
        let persisted = try SessionStore(url: directory.appendingPathComponent("session.json"))
        try expect(persisted.snapshot.microphones.count == 2)
        try expectThrows { try microphone.selectDefault() }
        hardware.failMuteDevice = nil
        try expect(try microphone.selectDefault() == false)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testFailedJournalWriteCannotBeBypassedOnRetry() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.7)
        let journal = directory.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try expectThrows { try microphone.selectDefault() }
            try expect(store.snapshot.microphones.isEmpty)
            try expect(hardware.writes.isEmpty)
            try expect(microphone.current == nil)
        }
        try FileManager.default.removeItem(at: journal)
        try microphone.selectDefault()
        let persisted = try SessionStore(url: journal)
        try expect(persisted.snapshot.microphones.first?.controls.first?.original == 0.7)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testCancelledQueuedPressNeverRaisesGain() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 0, value: 0.7)
        try microphone.selectDefault()
        hardware.writes = []
        let authorization = TalkAuthorization()
        let press = authorization.request(true)
        authorization.request(false)
        try microphone.setTalking(true, canUnmute: { authorization.allowsUnmute(press) })
        try expect(hardware.writes.isEmpty)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 0) == 0)
    }

    func testReleaseDuringSlowReadPreventsUnmuteWrite() throws {
        hardware.add(selector: kAudioDevicePropertyMute, element: 0, value: 0)
        try microphone.selectDefault()
        hardware.writes = []
        let authorization = TalkAuthorization()
        let press = authorization.request(true)
        hardware.onRead = { authorization.request(false) }
        try microphone.setTalking(true, canUnmute: { authorization.allowsUnmute(press) })
        hardware.onRead = nil
        try expect(hardware.writes.isEmpty)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyMute, element: 0) == 1)
    }

    func testReleaseDuringWriteRemutesBeforeNextChannelOpens() throws {
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 1, value: 0.7)
        hardware.add(selector: kAudioDevicePropertyVolumeScalar, element: 2, value: 0.7)
        try microphone.selectDefault()
        hardware.writes = []
        let authorization = TalkAuthorization()
        let press = authorization.request(true)
        hardware.onWrite = { level in if level > 0 { authorization.request(false) } }
        try microphone.setTalking(true, canUnmute: { authorization.allowsUnmute(press) })
        hardware.onWrite = nil
        try expect(hardware.writes.filter { $0.2 > 0 }.count == 1)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 1) == 0)
        try expect(try hardware.read(1, selector: kAudioDevicePropertyVolumeScalar, element: 2) == 0)
    }
}
