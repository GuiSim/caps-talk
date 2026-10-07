import Foundation

struct TalkRequest {
    let generation: UInt64
    let talking: Bool
}

// Main-thread key events can revoke queued work without waiting for a busy audio driver.
final class TalkAuthorization {
    private let lock = NSLock()
    private var request = TalkRequest(generation: 0, talking: false)

    @discardableResult
    func request(_ talking: Bool) -> TalkRequest {
        lock.lock()
        defer { lock.unlock() }
        request = TalkRequest(generation: request.generation &+ 1, talking: talking)
        return request
    }

    var current: TalkRequest {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func isCurrent(_ candidate: TalkRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.generation == candidate.generation
    }

    func allowsUnmute(_ candidate: TalkRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate.talking && request.talking && request.generation == candidate.generation
    }
}
