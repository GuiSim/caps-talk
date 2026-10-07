import AppKit
import ApplicationServices
import CoreAudio
import Darwin

let arguments = CommandLine.arguments

if arguments.contains("--watchdog") {
    guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[2]) else {
        fputs("CapsTalk recovery requires a session identifier.\n", stderr)
        exit(1)
    }
    // An anonymous pipe closes automatically if the GUI is killed or crashes.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if String(data: data, encoding: .utf8) == "clean" { exit(0) }
    do {
        try SessionRecovery.run(sessionID: sessionID) { store in
            Microphone(store: store).muteAllSaved()
            try KeyRemapper(store: store).restore()
        }
    } catch { fputs("CapsTalk recovery: \(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

if arguments.contains("--diagnose") {
    do {
        let hardware = CoreAudioHardware()
        print("Accessibility: \(AXIsProcessTrusted() ? "allowed" : "not granted")")
        print("Input Monitoring: \(CGPreflightListenEventAccess() ? "allowed" : "not granted")")
        let device = try hardware.defaultInput()
        print("Default input: \(try hardware.string(device, selector: kAudioObjectPropertyName))")
        let channels = try hardware.channelCount(device)
        print("Input channels: \(channels)")
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
            for element in 0...channels where hardware.isWritable(device, selector: selector, element: element) {
                print("\(selector == kAudioDevicePropertyMute ? "Mute" : "Volume") element \(element): \(try hardware.read(device, selector: selector, element: element)) (writable)")
            }
        }
        for line in KeyRemapper(store: try SessionStore()).diagnostics() { print(line) }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

// A lock also covers launches outside Launch Services (swift run, direct executable).
let sessionLock: SessionLock
do { sessionLock = try SessionLock() } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(0)
}

if arguments.contains("--restore") {
    do {
        let store = try SessionStore()
        try KeyRemapper(store: store).restore()
        try Microphone(store: store).restoreAll()
        print("Original keyboard mappings and microphone settings restored.")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(releaseSessionLock: { sessionLock.release() })
app.delegate = delegate
app.run()
