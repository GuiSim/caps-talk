import Foundation

// Failed steps remain pending. Successful steps run once, so retry completes all initialization.
final class StartupCoordinator {
    private let steps: [() throws -> Void]
    private var completed = 0

    init(steps: [() throws -> Void]) { self.steps = steps }
    var isReady: Bool { completed == steps.count }

    func prepare() throws {
        while completed < steps.count {
            try steps[completed]()
            completed += 1
        }
    }

    func reset() { completed = 0 }
}
