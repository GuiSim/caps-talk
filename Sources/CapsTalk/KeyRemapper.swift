import Foundation
import CoreGraphics
import IOKit.hidsystem
import IOKit

protocol KeyboardHardwareAccess {
    func keyboardIDs() -> [UInt64]
    func mappings(for registryID: UInt64) throws -> [KeyMapping]
    func write(_ mappings: [KeyMapping], to registryID: UInt64) throws
}

final class HIDKeyboardHardware: KeyboardHardwareAccess {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let property = "UserKeyMapping" as CFString
    private var services: [UInt64: IOHIDServiceClient] = [:]

    func keyboardIDs() -> [UInt64] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        services = [:]
        for service in all where IOHIDServiceClientConformsTo(service, 1, 6) != 0 {
            let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
            services[id] = service
        }
        return services.keys.sorted()
    }

    private func service(_ registryID: UInt64) throws -> IOHIDServiceClient {
        guard let service = services[registryID] else { throw AppError("This keyboard was disconnected.") }
        return service
    }

    func mappings(for registryID: UInt64) throws -> [KeyMapping] {
        guard let value = IOHIDServiceClientCopyProperty(try service(registryID), property) else { return [] }
        guard let entries = value as? [[String: NSNumber]] else {
            throw AppError("Cannot read this keyboard’s existing key mappings.")
        }
        return try entries.map { entry in
            guard let source = entry["HIDKeyboardModifierMappingSrc"],
                  let destination = entry["HIDKeyboardModifierMappingDst"] else {
                throw AppError("This keyboard has an unrecognized key mapping.")
            }
            return KeyMapping(source: source.uint64Value, destination: destination.uint64Value)
        }
    }

    func write(_ mappings: [KeyMapping], to registryID: UInt64) throws {
        guard IOHIDServiceClientSetProperty(try service(registryID), property, mappings.map(\.dictionary) as CFArray) else {
            throw AppError("macOS refused the Caps Lock remap. Check Input Monitoring permission.")
        }
    }
}

final class KeyRemapper {
    private let hardware: KeyboardHardwareAccess
    private let store: SessionStore

    init(store: SessionStore, hardware: KeyboardHardwareAccess = HIDKeyboardHardware()) {
        self.store = store
        self.hardware = hardware
    }

    func clearCapsLock() throws {
        guard CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { throw AppError("Turn Caps Lock off before enabling CapsTalk.") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else {
            throw AppError("Turn Caps Lock off before enabling CapsTalk.")
        }
        defer { IOServiceClose(connection) }
        guard IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS else {
            throw AppError("Turn Caps Lock off before enabling CapsTalk.")
        }
    }

    private func write(_ mappings: [KeyMapping], to registryID: UInt64) throws {
        try hardware.write(mappings, to: registryID)
        guard try hardware.mappings(for: registryID) == mappings else {
            throw AppError("The Caps Lock mapping could not be verified.")
        }
    }

    func install() throws {
        let keyboards = hardware.keyboardIDs()
        guard !keyboards.isEmpty else { throw AppError("No keyboard is connected.") }
        for registryID in keyboards {
            guard registryID != 0 else { throw AppError("Cannot identify this keyboard.") }
            let current = try hardware.mappings(for: registryID)
            if !store.snapshot.keyboards.contains(where: { $0.registryID == registryID }) {
                // Persist BEFORE touching the keyboard so the watchdog can always undo our changes.
                try store.update { $0.keyboards.append(KeyboardSnapshot(registryID: registryID, mappings: current)) }
            }
            let desired = KeyMapping.installing(in: current)
            if desired != current { try write(desired, to: registryID) }
        }
    }

    func restore() throws {
        var firstError: Error?
        for registryID in hardware.keyboardIDs() {
            guard let original = store.snapshot.keyboards.first(where: { $0.registryID == registryID }) else { continue }
            do {
                let current = try hardware.mappings(for: registryID)
                let restored = KeyMapping.restoring(current, original: original.mappings)
                if restored != current { try write(restored, to: registryID) }
            } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        try store.update { $0.keyboards = [] }
    }

    func diagnostics() -> [String] {
        hardware.keyboardIDs().map { id in
            "Keyboard \(id): \((try? hardware.mappings(for: id).map { String(format: "%llx → %llx", $0.source, $0.destination) }.joined(separator: ", ")) ?? "unreadable")"
        }
    }
}
