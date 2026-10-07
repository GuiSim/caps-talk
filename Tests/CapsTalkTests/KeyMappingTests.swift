import Foundation

private final class FakeKeyboardHardware: KeyboardHardwareAccess {
    var mappings = [KeyMapping(source: KeyMapping.capsLock, destination: 0x700000029)]
    var writes = 0
    func keyboardIDs() -> [UInt64] { [1] }
    func mappings(for registryID: UInt64) throws -> [KeyMapping] { mappings }
    func write(_ mappings: [KeyMapping], to registryID: UInt64) throws { self.mappings = mappings; writes += 1 }
}

struct KeyMappingTests {
    func testInstallPreservesOtherMappingsAndReplacesExistingCapsLockMapping() throws {
        let other = KeyMapping(source: 4, destination: 5)
        let oldCaps = KeyMapping(source: KeyMapping.capsLock, destination: 0x700000029)
        let installed = KeyMapping.installing(in: [other, oldCaps])
        try expect(installed == [other, KeyMapping(source: KeyMapping.capsLock, destination: KeyMapping.pushToTalk)])
        try expect(KeyMapping.restoring(installed, original: [other, oldCaps]) == [other, oldCaps])
    }

    func testRestorePreservesUnrelatedChangesMadeDuringSession() throws {
        let original = [KeyMapping(source: 4, destination: 5)]
        let added = KeyMapping(source: 6, destination: 7)
        let current = KeyMapping.installing(in: original) + [added]
        try expect(KeyMapping.restoring(current, original: original) == original + [added])
    }

    func testRestoreDoesNotOverwriteNewCapsLockMappingFromAnotherApp() throws {
        let changed = [KeyMapping(source: KeyMapping.capsLock, destination: 0x7000000E0)]
        try expect(KeyMapping.restoring(changed, original: []) == changed)
    }

    func testFailedJournalWriteNeverInstallsUnrecordedMapping() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        let store = try SessionStore(url: journal)
        let hardware = FakeKeyboardHardware()
        let original = hardware.mappings
        let remapper = KeyRemapper(store: store, hardware: hardware)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try expectThrows { try remapper.install() }
            try expect(store.snapshot.keyboards.isEmpty)
            try expect(hardware.writes == 0)
            try expect(hardware.mappings == original)
        }
        try FileManager.default.removeItem(at: journal)
        try remapper.install()
        let persisted = try SessionStore(url: journal)
        try expect(persisted.snapshot.keyboards.first?.mappings == original)
        try remapper.restore()
        try expect(hardware.mappings == original)
        try expect(store.snapshot.keyboards.isEmpty)
    }
}
