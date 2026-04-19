import Foundation

struct TestStepResult: Sendable {
    enum Status: Sendable {
        case passed
        case failed
    }

    let action: TestAction
    let status: Status
    let duration: TimeInterval
    let message: String?
}

struct TestRunResult: Sendable {
    let steps: [TestStepResult]

    var passed: Bool { steps.allSatisfy { $0.status == .passed } }
    var failedCount: Int { steps.filter { $0.status == .failed }.count }
    var passedCount: Int { steps.filter { $0.status == .passed }.count }
}

actor TestResultCollector {
    private var results: [TestStepResult] = []

    func append(_ step: TestStepResult) {
        results.append(step)
    }

    func drain() -> [TestStepResult] {
        let current = results
        results.removeAll()
        return current
    }
}
