import AppKit
import ApplicationServices
import Carbon
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: SessionStore!
    private var microphone: Microphone!
    private var remapper: KeyRemapper!
    private let hook = KeyboardHook()
    private let audioQueue = DispatchQueue(label: "app.capstalk.audio", qos: .userInteractive)
    private let authorization = TalkAuthorization()
    private let sessionID = UUID()
    private let releaseSessionLock: () -> Void
    private lazy var startup = StartupCoordinator(steps: [
        { [unowned self] in try initializeRuntime() },
        { [unowned self] in installKeyboardCallbacks() },
        { [unowned self] in installMonitoring() }
    ])
    private var watchdog: Process?
    private var watchdogPipe: Pipe?
    private var timer: Timer?
    private var enabled = false
    private var wantsEnabled = true
    private var sleeping = false
    private var suspended = false
    private var talking = false
    private var message = "Starting…"
    private var inputName = "No input selected"
    private var volume: Float = 0.75
    private var canAdjustVolume = false
    private var lastMappingCheck = Date.distantPast
    private var stateVersion = 0
    private var tickPending = false
    private var mappingHealthy = true
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var observers: [NSObjectProtocol] = []

    init(releaseSessionLock: @escaping () -> Void = {}) {
        self.releaseSessionLock = releaseSessionLock
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
        startIfAllowed()
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Allow CapsTalk to use Caps Lock"
            alert.informativeText = "Enable CapsTalk in System Settings → Privacy & Security → Accessibility. Add this app with the + button if needed. If macOS also requests Input Monitoring, enable that too. CapsTalk will start automatically once access is granted.\n\nWhile enabled, hold Caps Lock to talk and release it to mute your default system microphone."
            alert.addButton(withTitle: "Open Accessibility")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openAccessibility() }
        }
    }

    private func initializeRuntime() throws {
        let candidateStore = try SessionStore()
        let candidateMicrophone = Microphone(store: candidateStore)
        let candidateRemapper = KeyRemapper(store: candidateStore)
        candidateMicrophone.muteAllSaved()
        try candidateRemapper.restore()
        try candidateStore.claim(sessionID)
        try startWatchdog()
        // Publish dependencies only once the complete recovery setup succeeds.
        store = candidateStore
        microphone = candidateMicrophone
        remapper = candidateRemapper
    }

    private func installKeyboardCallbacks() {
        hook.onChange = { [weak self] held in self?.changeTalking(held) }
        hook.onInterruption = { [weak self] in self?.changeTalking(false) }
    }

    private func installMonitoring() {
        if observers.isEmpty { installObservers() }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    private func startWatchdog() throws {
        guard let executable = Bundle.main.executableURL else { throw AppError("Cannot locate the CapsTalk executable.") }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--watchdog", sessionID.uuidString]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        watchdog = process
        watchdogPipe = pipe
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.hook.forceRelease()
            self?.changeTalking(false)
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.lastMappingCheck = .distantPast
            self?.tick()
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = true
            self?.hook.forceRelease()
            self?.changeTalking(false)
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = false
            self?.tick()
        })
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.hook.forceRelease()
            self?.changeTalking(false)
            self?.tick()
        }
        systemListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    private func startIfAllowed() {
        guard wantsEnabled, !enabled else { return }
        do {
            if let watchdog, !watchdog.isRunning { startup.reset() }
            try startup.prepare()
        } catch {
            message = error.localizedDescription
            render()
            return
        }
        guard AXIsProcessTrusted() else {
            message = "Accessibility permission needed"
            render()
            return
        }
        do {
            try hook.start() // Establish interception BEFORE remapping any key.
            try remapper.clearCapsLock()
            try audioQueue.sync { _ = try microphone.selectDefault(); try microphone.setTalking(false) }
            try audioQueue.sync { try remapper.install() }
            enabled = true
            mappingHealthy = true
            message = "Muted · hold Caps Lock to talk"
            updateDeviceInfo()
            render()
        } catch {
            hook.stop()
            try? audioQueue.sync { try remapper.restore() }
            audioQueue.sync { microphone.muteAllSaved() }
            message = error.localizedDescription
            render()
        }
    }

    private func updateDeviceInfo() {
        let snapshot = audioQueue.sync { microphone.current }
        inputName = snapshot?.name ?? "No input selected"
        volume = snapshot?.talkVolume ?? 0.75
        canAdjustVolume = snapshot?.controls.contains { $0.selector == kAudioDevicePropertyVolumeScalar } ?? false
    }

    private func changeTalking(_ requested: Bool) {
        guard enabled else { return }
        let desired = requested && enabled && !sleeping && !suspended && !IsSecureEventInputEnabled()
        talking = desired
        let request = authorization.request(desired)
        stateVersion += 1
        let version = stateVersion
        audioQueue.async { [weak self] in
            guard let self, self.authorization.isCurrent(request) else { return }
            do {
                // A hotplug can precede the default-input notification: never open the new input on an old press.
                let changed = try self.microphone.selectDefault()
                if changed { self.authorization.request(false) }
                try self.microphone.setTalking(desired && !changed, canUnmute: { self.authorization.allowsUnmute(request) })
                DispatchQueue.main.async {
                    guard self.enabled else { return }
                    if changed {
                        self.hook.forceRelease()
                        self.talking = false
                        self.stateVersion += 1
                        self.updateDeviceInfo()
                        self.message = "Muted · hold Caps Lock to talk"
                        self.render()
                        return
                    }
                    guard version == self.stateVersion else { return }
                    self.message = self.talking ? "Live · release Caps Lock to mute" : "Muted · hold Caps Lock to talk"
                    self.render()
                }
            } catch {
                self.authorization.request(false)
                self.microphone.muteAllSaved()
                DispatchQueue.main.async {
                    guard self.enabled else { return }
                    self.talking = false
                    self.hook.forceRelease()
                    self.stateVersion += 1
                    self.message = error.localizedDescription
                    self.render()
                }
            }
        }
    }

    private func tick() {
        guard store != nil else { return }
        if !enabled {
            if wantsEnabled && Date().timeIntervalSince(lastMappingCheck) > 2 {
                lastMappingCheck = Date()
                startIfAllowed()
            }
            return
        }
        if !AXIsProcessTrusted() || watchdog?.isRunning != true {
            stop(restoringAudio: false)
            message = AXIsProcessTrusted() ? "Recovery helper stopped. Quit and reopen CapsTalk." : "Accessibility permission needed"
            if watchdog?.isRunning != true { wantsEnabled = false }
            render()
            return
        }
        hook.checkRelease()
        if sleeping || suspended || IsSecureEventInputEnabled() {
            authorization.request(false)
            hook.forceRelease()
            talking = false
            message = "Muted · keyboard access paused"
            render()
        }
        if Date().timeIntervalSince(lastMappingCheck) > 2 {
            lastMappingCheck = Date()
            do { try audioQueue.sync { try remapper.install() }; mappingHealthy = true } catch {
                authorization.request(false)
                mappingHealthy = false
                hook.forceRelease()
                talking = false
                message = error.localizedDescription
                audioQueue.async { [weak self] in self?.microphone.muteAllSaved() }
                render()
                return
            }
        }
        guard !tickPending else { return }
        tickPending = true
        let shouldTalk = talking
        let request = authorization.current
        let version = stateVersion
        audioQueue.async { [weak self] in
            guard let self else { return }
            var changed = false
            var failure: Error?
            do {
                changed = try self.microphone.selectDefault()
                if changed { self.authorization.request(false) }
                // Reassert mute while idle, since meeting apps may change system gain themselves.
                if changed || (!shouldTalk && self.authorization.isCurrent(request)) { try self.microphone.setTalking(false) }
            } catch { failure = error; self.authorization.request(false); self.microphone.muteAllSaved() }
            DispatchQueue.main.async {
                self.tickPending = false
                guard self.enabled else { return }
                // Device changes and failures invalidate all presses, including work queued during a slow read.
                if changed {
                    self.hook.forceRelease()
                    self.talking = false
                    self.updateDeviceInfo()
                    self.stateVersion += 1
                    self.message = "Muted · hold Caps Lock to talk"
                }
                if let failure {
                    self.talking = false
                    self.hook.forceRelease()
                    self.stateVersion += 1
                    self.message = failure.localizedDescription
                } else if version == self.stateVersion && self.mappingHealthy && !self.talking && !self.sleeping && !self.suspended && !IsSecureEventInputEnabled() {
                    self.message = "Muted · hold Caps Lock to talk"
                }
                self.render()
            }
        }
    }

    @discardableResult
    private func stop(restoringAudio: Bool) -> Bool {
        enabled = false
        talking = false
        authorization.request(false)
        stateVersion += 1
        hook.stop()
        audioQueue.sync { microphone?.muteAllSaved() }
        var failures: [String] = []
        do { try audioQueue.sync { try remapper?.restore() } } catch { failures.append(error.localizedDescription) }
        if restoringAudio {
            do { try audioQueue.sync { try microphone?.restoreAll() } } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { message = "Recovery needed: " + failures.joined(separator: " ") }
        return failures.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        let restored = stop(restoringAudio: true)
        if restored { try? watchdogPipe?.fileHandleForWriting.write(contentsOf: Data("clean".utf8)) }
        // The helper must be able to acquire the same lock after EOF; release before waiting for it.
        releaseSessionLock()
        try? watchdogPipe?.fileHandleForWriting.close()
        if let watchdog { watchdog.waitUntilExit() }
        if let systemListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func render() {
        guard statusItem != nil else { return }
        let good = enabled && (message.hasPrefix("Muted") || message.hasPrefix("Live"))
        let symbol = good ? (talking ? "mic.fill" : "mic.slash.fill") : "mic.badge.xmark"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: message)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = talking ? .systemGreen : nil
        statusItem.button?.toolTip = "CapsTalk: \(message)\n\(inputName)"
        statusItem.button?.setAccessibilityLabel("CapsTalk, \(message)")
        if statusItem.menu == nil { rebuildMenu() }
    }

    private func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func rebuildMenu() {
        let menu = statusItem.menu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        menu.addItem(item("CapsTalk"))
        menu.addItem(item(message))
        menu.addItem(item(inputName))
        menu.addItem(.separator())
        menu.addItem(item("Hold Caps Lock → talk"))
        menu.addItem(item("Release Caps Lock → mute"))
        if enabled && canAdjustVolume {
            menu.addItem(.separator())
            menu.addItem(item("Speaking input level"))
            let slider = NSSlider(value: Double(volume), minValue: 0.01, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
            slider.frame = NSRect(x: 16, y: 8, width: 210, height: 24)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 242, height: 40))
            view.addSubview(slider)
            slider.setAccessibilityLabel("Speaking microphone input volume")
            let sliderItem = NSMenuItem()
            sliderItem.view = view
            menu.addItem(sliderItem)
        }
        menu.addItem(.separator())
        menu.addItem(item(enabled ? "Pause & restore mic / Caps Lock" : "Enable / Retry", #selector(toggleEnabled)))
        menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        menu.addItem(item("Open Input Monitoring Settings…", #selector(openInputMonitoring)))
        menu.addItem(item("Open Sound Settings…", #selector(openSound)))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit & restore mic / Caps Lock", #selector(quit)))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    @objc private func volumeChanged(_ sender: NSSlider) {
        volume = Float(sender.doubleValue)
        let level = volume
        let held = talking
        let request = authorization.current
        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.microphone.setTalkVolume(level)
                if held { try self.microphone.setTalking(true, canUnmute: { self.authorization.allowsUnmute(request) }) }
            }
            catch { DispatchQueue.main.async { self.showError(error.localizedDescription) } }
        }
    }

    @objc private func toggleEnabled() {
        if enabled {
            wantsEnabled = false
            if stop(restoringAudio: true) { message = "Paused · original settings restored" }
            render()
        } else {
            wantsEnabled = true
            startIfAllowed()
            if !AXIsProcessTrusted() { openAccessibility() }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(error.localizedDescription) }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openInputMonitoring() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func openSound() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "CapsTalk"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
