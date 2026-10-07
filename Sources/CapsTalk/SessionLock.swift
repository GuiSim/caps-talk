import Darwin
import Foundation

final class SessionLock {
    static let url = SessionStore.directory.appendingPathComponent("app.lock")
    private var descriptor: Int32?

    init(url: URL = SessionLock.url, wait: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppError("Cannot open CapsTalk’s session lock (\(errno)).") }
        var result: Int32
        repeat { result = flock(fd, wait ? LOCK_EX : LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            close(fd)
            throw AppError(code == EWOULDBLOCK ? "CapsTalk is running or finishing recovery." : "Cannot lock CapsTalk’s session (\(code)).")
        }
        descriptor = fd
    }

    func release() {
        if let descriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            self.descriptor = nil
        }
    }

    deinit { release() }
}

enum SessionRecovery {
    @discardableResult
    static func run(sessionID: UUID, journalURL: URL = SessionStore.url, lockURL: URL = SessionLock.url,
                    recover: (SessionStore) throws -> Void) throws -> Bool {
        let lock = try SessionLock(url: lockURL, wait: true)
        defer { lock.release() }
        // Read AFTER acquiring the lock. A relaunched app may already own a newer session.
        let store = try SessionStore(url: journalURL)
        guard store.snapshot.sessionID == sessionID else { return false }
        try recover(store)
        try store.update { $0.sessionID = nil }
        return true
    }
}
