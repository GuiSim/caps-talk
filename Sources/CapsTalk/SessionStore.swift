import Foundation

struct KeyMapping: Codable, Equatable {
    let source: UInt64
    let destination: UInt64

    static let capsLock: UInt64 = 0x700000039
    static let pushToTalk: UInt64 = 0x70000006F // F20: a normal key with down AND up events.

    var dictionary: [String: UInt64] {
        ["HIDKeyboardModifierMappingSrc": source, "HIDKeyboardModifierMappingDst": destination]
    }

    static func installing(in mappings: [KeyMapping]) -> [KeyMapping] {
        mappings.filter { $0.source != capsLock } + [KeyMapping(source: capsLock, destination: pushToTalk)]
    }

    // Only undo our own mapping. Preserve changes made by other tools during the session.
    static func restoring(_ current: [KeyMapping], original: [KeyMapping]) -> [KeyMapping] {
        guard current.contains(KeyMapping(source: capsLock, destination: pushToTalk)) else { return current }
        return current.filter { $0.source != capsLock } + original.filter { $0.source == capsLock }
    }
}

struct KeyboardSnapshot: Codable {
    let registryID: UInt64
    let mappings: [KeyMapping]
}

struct SessionSnapshot: Codable {
    // Optional so journals from version 1.0 can still be recovered.
    var sessionID: UUID?
    var keyboards: [KeyboardSnapshot] = []
    var microphones: [MicrophoneSnapshot] = []
}

final class SessionStore {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CapsTalk", isDirectory: true)
    static let url = directory.appendingPathComponent("session.json")
    private let fileURL: URL
    private(set) var snapshot: SessionSnapshot

    init(url: URL = SessionStore.url) throws {
        fileURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url))
        } else {
            snapshot = SessionSnapshot()
        }
    }

    func update(_ mutation: (inout SessionSnapshot) -> Void) throws {
        var candidate = snapshot
        mutation(&candidate)
        // A failed write must never create an in-memory record that a retry mistakes for durable data.
        try JSONEncoder().encode(candidate).write(to: fileURL, options: .atomic)
        snapshot = candidate
    }

    func claim(_ sessionID: UUID) throws {
        try update { $0.sessionID = sessionID }
    }
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
