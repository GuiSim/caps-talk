import Foundation

struct RuntimeTests {
    func testStartupRetryCompletesCallbacksAndMonitoring() throws {
        // A failed journal read, recovery write, or helper launch follows this same preparation path.
        for failedStage in 0..<3 {
            var fail = true
            var calls: [Int] = []
            let startup = StartupCoordinator(steps: (0..<3).map { stage in
                {
                    calls.append(stage)
                    if stage == failedStage && fail { throw AppError("Startup failure") }
                }
            })
            try expectThrows { try startup.prepare() }
            try expect(!startup.isReady)
            fail = false
            try startup.prepare()
            try expect(startup.isReady)
            let completedCalls = calls
            try startup.prepare()
            try expect(calls == completedCalls)
            for stage in 0..<3 {
                try expect(calls.filter { $0 == stage }.count == (stage == failedStage ? 2 : 1))
            }
        }
    }

    func testStaleWatchdogWaitsForLockThenSkipsNewSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        let lockURL = directory.appendingPathComponent("app.lock")
        let owner = try SessionLock(url: lockURL)
        defer { owner.release() }
        try expectThrows { _ = try SessionLock(url: lockURL) }
        let store = try SessionStore(url: journal)
        let oldSession = UUID()
        let newSession = UUID()
        try store.claim(oldSession)

        let finished = DispatchSemaphore(value: 0)
        let results = RecoveryResults()
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                results.recovered = try SessionRecovery.run(sessionID: oldSession, journalURL: journal, lockURL: lockURL) { store in
                    results.actionCalled = true
                    try store.update { $0.keyboards = [] }
                }
            } catch { results.error = error }
        }
        try expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        try store.update {
            $0.sessionID = newSession
            $0.keyboards = [KeyboardSnapshot(registryID: 42, mappings: [])]
        }
        let expectedJournal = try Data(contentsOf: journal)
        owner.release()
        try expect(finished.wait(timeout: .now() + 3) == .success)
        if let error = results.error { throw error }
        try expect(!results.recovered && !results.actionCalled)
        try expect(try Data(contentsOf: journal) == expectedJournal)
    }

    func testMatchingWatchdogRecoversOnceAndKeepsMicrophoneRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        let lock = directory.appendingPathComponent("app.lock")
        let store = try SessionStore(url: journal)
        let session = UUID()
        try store.update {
            $0.sessionID = session
            $0.keyboards = [KeyboardSnapshot(registryID: 1, mappings: [])]
            $0.microphones = [MicrophoneSnapshot(uid: "fake", name: "fake", channelCount: 1,
                controls: [], muteSelector: 0, muteElements: [0], talkVolume: 0.6)]
        }
        var actions = 0
        try expect(try SessionRecovery.run(sessionID: session, journalURL: journal, lockURL: lock) { store in
            actions += 1
            try store.update { $0.keyboards = [] }
        })
        try expect(try SessionRecovery.run(sessionID: session, journalURL: journal, lockURL: lock) { _ in actions += 1 } == false)
        try expect(actions == 1)
        let recovered = try SessionStore(url: journal)
        try expect(recovered.snapshot.sessionID == nil)
        try expect(recovered.snapshot.keyboards.isEmpty)
        try expect(recovered.snapshot.microphones.count == 1)
    }

    func testLegacyJournalWithoutSessionIDCanBeClaimed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("session.json")
        try Data("{\"keyboards\":[],\"microphones\":[]}".utf8).write(to: journal)
        let store = try SessionStore(url: journal)
        try expect(store.snapshot.sessionID == nil)
        let session = UUID()
        try store.claim(session)
        try expect(try SessionStore(url: journal).snapshot.sessionID == session)
    }
}

// Access is synchronized by the completion semaphore before the test reads these values.
private final class RecoveryResults {
    var recovered = true
    var actionCalled = false
    var error: Error?
}
