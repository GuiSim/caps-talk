import CoreAudio
import Foundation

final class Microphone {
    private let hardware: AudioHardwareAccess
    private let store: SessionStore
    private var pendingMutes: Set<String> = []
    private(set) var device: AudioDeviceID?
    private(set) var current: MicrophoneSnapshot?

    init(store: SessionStore, hardware: AudioHardwareAccess = CoreAudioHardware()) {
        self.store = store
        self.hardware = hardware
    }

    private func completeElements(_ device: AudioDeviceID, selector: UInt32, channels: UInt32) -> [UInt32] {
        if hardware.isWritable(device, selector: selector, element: 0) { return [0] }
        let elements = Array(1...channels)
        return elements.allSatisfy { hardware.isWritable(device, selector: selector, element: $0) } ? elements : []
    }

    @discardableResult
    func selectDefault() throws -> Bool {
        let next = try hardware.defaultInput()
        let uid = try hardware.string(next, selector: kAudioDevicePropertyDeviceUID)
        if next == device && current?.uid == uid {
            try retryPendingMutes(excluding: uid)
            return false
        }
        // Device switches require a fresh press. Keep previously controlled inputs muted too.
        var previousFailure: Error?
        if let device, let current, (try? hardware.inputDevices().contains(device)) == true {
            do { try apply(talking: false, device: device, snapshot: current) }
            catch { pendingMutes.insert(current.uid); previousFailure = error }
        }
        device = nil
        current = nil
        let channels = try hardware.channelCount(next)
        guard channels > 0 else { throw AppError("This microphone has no input channels.") }
        let mutes = completeElements(next, selector: kAudioDevicePropertyMute, channels: channels)
        let volumes = completeElements(next, selector: kAudioDevicePropertyVolumeScalar, channels: channels)
        let selector = mutes.isEmpty ? kAudioDevicePropertyVolumeScalar : kAudioDevicePropertyMute
        let elements = mutes.isEmpty ? volumes : mutes
        guard !elements.isEmpty else {
            throw AppError("\(try hardware.string(next, selector: kAudioObjectPropertyName)) has no writable input mute or volume control.")
        }
        let saved = store.snapshot.microphones.first { $0.uid == uid }
        let snapshot: MicrophoneSnapshot
        if let saved, saved.channelCount == channels, saved.muteSelector == selector, saved.muteElements == elements {
            snapshot = saved
        } else {
            var controls: [AudioControl] = []
            for controlSelector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                // Capture every writable control we might touch, including partial channel mute controls.
                let writable = hardware.isWritable(next, selector: controlSelector, element: 0)
                    ? [UInt32(0)] : Array(1...channels).filter { hardware.isWritable(next, selector: controlSelector, element: $0) }
                for element in writable {
                    controls.append(AudioControl(selector: controlSelector, element: element,
                        original: try hardware.read(next, selector: controlSelector, element: element)))
                }
            }
            let levels = controls.filter { $0.selector == kAudioDevicePropertyVolumeScalar && $0.original > 0 }.map(\.original)
            let remembered = UserDefaults.standard.float(forKey: "talkVolume.\(uid)")
            snapshot = MicrophoneSnapshot(uid: uid, name: try hardware.string(next, selector: kAudioObjectPropertyName),
                channelCount: channels, controls: controls, muteSelector: selector, muteElements: elements,
                talkVolume: levels.max() ?? (remembered > 0 ? remembered : 0.75))
            try store.update {
                $0.microphones.removeAll { $0.uid == uid }
                $0.microphones.append(snapshot)
            }
        }
        device = next
        current = snapshot
        try setTalking(false)
        pendingMutes.remove(uid)
        // Surface the old input's failure only AFTER the new default input is recorded and muted.
        if let previousFailure { throw previousFailure }
        try retryPendingMutes(excluding: uid)
        return true
    }

    private func retryPendingMutes(excluding uid: String) throws {
        guard !pendingMutes.isEmpty else { return }
        let devices = try hardware.inputDevices()
        var firstError: Error?
        for pending in pendingMutes where pending != uid {
            guard let snapshot = store.snapshot.microphones.first(where: { $0.uid == pending }),
                  let device = devices.first(where: { (try? hardware.string($0, selector: kAudioDevicePropertyDeviceUID)) == pending }) else {
                pendingMutes.remove(pending)
                continue
            }
            do { try apply(talking: false, device: device, snapshot: snapshot); pendingMutes.remove(pending) }
            catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    private struct UnmuteCancelled: Error {}

    func setTalking(_ talking: Bool, canUnmute: () -> Bool = { true }) throws {
        guard let device, let current else { throw AppError("No controllable microphone is selected.") }
        if talking && !canUnmute() { return }
        do {
            try apply(talking: talking, device: device, snapshot: current, canUnmute: canUnmute)
        } catch is UnmuteCancelled {
            try apply(talking: false, device: device, snapshot: current)
        } catch {
            if talking { try? apply(talking: false, device: device, snapshot: current) }
            throw error
        }
    }

    private func set(_ value: Float, selector: UInt32, element: UInt32, device: AudioDeviceID,
                     canWrite: () -> Bool = { true }) throws {
        guard canWrite() else { throw UnmuteCancelled() }
        if try hardware.read(device, selector: selector, element: element) != value {
            // Reading a device property can block; recheck permission immediately before writing.
            guard canWrite() else { throw UnmuteCancelled() }
            try hardware.write(device, selector: selector, element: element, value: value)
        }
        guard canWrite() else { throw UnmuteCancelled() }
    }

    private func apply(talking: Bool, device: AudioDeviceID, snapshot: MicrophoneSnapshot,
                       canUnmute: () -> Bool = { true }) throws {
        if talking {
            // Set gain BEFORE lifting hardware mute, avoiding a burst at a stale level.
            let originalMaximum = snapshot.controls.filter { $0.selector == kAudioDevicePropertyVolumeScalar }.map(\.original).max() ?? 0
            for control in snapshot.controls where control.selector == kAudioDevicePropertyVolumeScalar {
                let level = control.original > 0 && originalMaximum > 0
                    ? control.original / originalMaximum * snapshot.talkVolume : snapshot.talkVolume
                try set(level, selector: control.selector, element: control.element, device: device, canWrite: canUnmute)
            }
            for control in snapshot.controls where control.selector == kAudioDevicePropertyMute {
                try set(0, selector: control.selector, element: control.element, device: device, canWrite: canUnmute)
            }
        } else {
            var firstError: Error?
            // Attempt every channel even if a write to an earlier channel fails.
            for element in snapshot.muteElements {
                do {
                    let value: Float = snapshot.muteSelector == kAudioDevicePropertyMute ? 1 : 0
                    try set(value, selector: snapshot.muteSelector, element: element, device: device)
                    let actual = try hardware.read(device, selector: snapshot.muteSelector, element: element)
                    guard abs(actual - value) < 0.0001 else { throw AppError("The microphone did not accept the mute setting.") }
                } catch { firstError = firstError ?? error }
            }
            if let firstError { throw firstError }
        }
    }

    func setTalkVolume(_ level: Float) throws {
        guard var snapshot = current, let device else { return }
        snapshot.talkVolume = min(1, max(0.01, level))
        try store.update {
            $0.microphones.removeAll { $0.uid == snapshot.uid }
            $0.microphones.append(snapshot)
        }
        current = snapshot
        UserDefaults.standard.set(snapshot.talkVolume, forKey: "talkVolume.\(snapshot.uid)")
        // Gain can be adjusted while hardware mute is engaged. Volume-based mute stays at zero.
        if snapshot.muteSelector == kAudioDevicePropertyMute {
            for control in snapshot.controls where control.selector == kAudioDevicePropertyVolumeScalar {
                try set(snapshot.talkVolume, selector: control.selector, element: control.element, device: device)
            }
        }
    }

    func restoreAll() throws {
        var firstError: Error?
        let devices = try hardware.inputDevices()
        for snapshot in store.snapshot.microphones {
            guard let device = devices.first(where: { (try? hardware.string($0, selector: kAudioDevicePropertyDeviceUID)) == snapshot.uid }) else { continue }
            // Restore gain first, then the original hardware mute state.
            for control in snapshot.controls.sorted(by: { $0.selector == kAudioDevicePropertyVolumeScalar && $1.selector != kAudioDevicePropertyVolumeScalar }) {
                do { try hardware.write(device, selector: control.selector, element: control.element, value: control.original) }
                catch { firstError = firstError ?? error }
            }
        }
        if let firstError { throw firstError }
        try store.update { $0.microphones = [] }
        pendingMutes = []
        device = nil
        current = nil
    }

    func muteAllSaved() {
        guard let devices = try? hardware.inputDevices() else { return }
        for snapshot in store.snapshot.microphones {
            guard let device = devices.first(where: { (try? hardware.string($0, selector: kAudioDevicePropertyDeviceUID)) == snapshot.uid }) else { continue }
            try? apply(talking: false, device: device, snapshot: snapshot)
        }
    }
}
