import OSLog
import SwiftUI

/// The groups on the Scenarios tab, each with its own color and symbol.
enum ScenarioGroup: String, CaseIterable, Identifiable {
    case local, roundTrip, ghost, relaunch, failures

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Local"
        case .roundTrip: "Round trip"
        case .ghost: "Ghost"
        case .relaunch: "Relaunch"
        case .failures: "Failures"
        }
    }

    var symbol: String {
        switch self {
        case .local: "iphone"
        case .roundTrip: "arrow.triangle.2.circlepath.icloud"
        case .ghost: "person.2.wave.2"
        case .relaunch: "arrow.clockwise.circle"
        case .failures: "exclamationmark.icloud"
        }
    }

    var color: Color {
        switch self {
        case .local: .blue
        case .roundTrip: .teal
        case .ghost: .purple
        case .relaunch: .orange
        case .failures: .red
        }
    }

    var summary: String {
        switch self {
        case .local: "Records on this device only, in throwaway containers. No iCloud."
        case .roundTrip: "Records sent to iCloud, erased here, and fetched back."
        case .ghost: "A second device, played by the Lab, edits the same records in iCloud."
        case .relaunch: "Steps that need the app swiped away and opened again."
        case .failures: "Errors iCloud can return, and how sync recovers."
        }
    }
}

/// One test the Lab can run.
struct Scenario: Identifiable {
    let id: String
    let group: ScenarioGroup
    let title: String
    let symbol: String
    let summary: String
    let run: @MainActor (Lab) async throws -> Void
}

/// A check that didn't hold: which step, what it expected, and what it found.
struct LabFailure: Error, CustomStringConvertible {
    let step: String
    let expected: String
    let actual: String

    var description: String { "\(step): expected \(expected), found \(actual)" }
}

/// One step of a run, as it happened.
struct Step: Identifiable {
    enum Kind {
        case act, check, wait, ask, metric

        var symbol: String {
            switch self {
            case .act: "bolt.fill"
            case .check: "checkmark.seal"
            case .wait: "hourglass"
            case .ask: "person.fill.questionmark"
            case .metric: "gauge.with.dots.needle.67percent"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let name: String
    var status: Outcome.Status = .running
    var duration: Duration?
    var detail: String?
}

/// A scenario's latest run.
struct Outcome {
    enum Status { case running, passed, failed }

    var status: Status = .running
    var steps: [Step] = []
    var duration: Duration?
    var failure: String?
}

/// A question that pauses a scenario until the user answers it.
struct Question: Identifiable {
    enum Answers { case yesNo, done }

    let id = UUID()
    let title: String
    let detail: String
    let answers: Answers
    let content: AnyView?
    let reply: @MainActor (Bool) -> Void
}

/// Runs scenarios one at a time and keeps each one's latest outcome.
///
/// Every result is also printed with a `LAB` prefix and logged, so whoever runs the app from
/// Xcode or a terminal sees each failure with its step, what was expected, and what was found.
@MainActor
@Observable
final class Runner {
    private(set) var outcomes: [Scenario.ID: Outcome] = [:]
    private(set) var running: Scenario.ID?
    /// How far a Run All has got.
    private(set) var progress: (done: Int, total: Int)?
    /// The question on screen, if a scenario is waiting for an answer.
    var question: Question?

    static let log = Logger(subsystem: "RecordsLab", category: "Scenarios")

    func run(_ scenario: Scenario) async {
        guard running == nil else { return }
        await perform(scenario)
    }

    func runAll(_ scenarios: [Scenario]) async {
        guard running == nil, !scenarios.isEmpty else { return }
        progress = (0, scenarios.count)
        for scenario in scenarios {
            await perform(scenario)
            progress?.done += 1
        }
        let failed = scenarios.filter { outcomes[$0.id]?.status == .failed }.map(\.id)
        var line = "LAB SUMMARY \(scenarios.count - failed.count) passed, \(failed.count) failed"
        if !failed.isEmpty { line += ": " + failed.joined(separator: ", ") }
        report(line, failed: !failed.isEmpty)
        progress = nil
    }

    /// Answers the question on screen. Later taps do nothing.
    func answer(_ value: Bool) {
        guard let question else { return }
        self.question = nil
        question.reply(value)
    }

    func clear() {
        guard running == nil else { return }
        outcomes = [:]
    }

    private func perform(_ scenario: Scenario) async {
        running = scenario.id
        outcomes[scenario.id] = Outcome()
        let start = ContinuousClock.now
        var failure: String?
        do {
            try await scenario.run(Lab(runner: self, scenario: scenario.id))
        } catch {
            failure = String(describing: error)
        }
        let duration = ContinuousClock.now - start
        outcomes[scenario.id]?.duration = duration
        outcomes[scenario.id]?.failure = failure
        outcomes[scenario.id]?.status = failure == nil ? .passed : .failed
        if let failure {
            report("LAB FAIL \(scenario.id) after \(duration.label): \(failure)", failed: true)
        } else {
            report("LAB PASS \(scenario.id) in \(duration.label)", failed: false)
        }
        running = nil
    }

    private func report(_ line: String, failed: Bool) {
        print(line)
        if failed {
            Self.log.error("\(line, privacy: .public)")
        } else {
            Self.log.notice("\(line, privacy: .public)")
        }
    }

    fileprivate func begin(_ kind: Step.Kind, _ name: String, in scenario: Scenario.ID) -> Int {
        outcomes[scenario, default: Outcome()].steps.append(Step(kind: kind, name: name))
        return (outcomes[scenario]?.steps.count ?? 1) - 1
    }

    fileprivate func end(_ index: Int, in scenario: Scenario.ID, passed: Bool, since start: ContinuousClock.Instant? = nil, detail: String? = nil) {
        guard var step = outcomes[scenario]?.steps[index] else { return }
        step.status = passed ? .passed : .failed
        step.duration = start.map { ContinuousClock.now - $0 }
        step.detail = detail
        outcomes[scenario]?.steps[index] = step
    }
}

/// What a scenario uses to act, check, wait and ask. Each call adds a step to the run, with
/// its duration and result.
@MainActor
final class Lab {
    private let runner: Runner
    let scenario: Scenario.ID

    fileprivate init(runner: Runner, scenario: Scenario.ID) {
        self.runner = runner
        self.scenario = scenario
    }

    /// Does something and times it. An error fails the step and the scenario.
    @discardableResult
    func act(_ name: String, _ body: @MainActor () async throws -> Void) async throws -> Duration {
        let index = runner.begin(.act, name, in: scenario)
        let start = ContinuousClock.now
        do {
            try await body()
        } catch {
            runner.end(index, in: scenario, passed: false, since: start, detail: String(describing: error))
            throw error
        }
        let duration = ContinuousClock.now - start
        runner.end(index, in: scenario, passed: true, since: start)
        return duration
    }

    /// Fails the scenario unless `condition` holds.
    func check(_ name: String, _ condition: Bool, expected: String = "true", actual: String = "false") throws {
        let index = runner.begin(.check, name, in: scenario)
        runner.end(index, in: scenario, passed: condition, detail: condition ? nil : "Expected \(expected), found \(actual)")
        if !condition { throw LabFailure(step: name, expected: expected, actual: actual) }
    }

    /// Fails the scenario unless `actual` equals `expected`.
    func expect<T: Equatable>(_ name: String, _ actual: T, _ expected: T) throws {
        try check(name, actual == expected, expected: String(describing: expected), actual: String(describing: actual))
    }

    /// The value, or a failure when it is `nil`.
    func unwrap<T>(_ name: String, _ value: T?) throws -> T {
        try check(name, value != nil, expected: "a value", actual: "nil")
        return value!
    }

    /// Waits until `condition` holds, checking ten times a second, and fails after `timeout`.
    func wait(_ name: String, timeout: Duration = .seconds(30), until condition: @MainActor () throws -> Bool) async throws {
        let index = runner.begin(.wait, name, in: scenario)
        let start = ContinuousClock.now
        while try !condition() {
            if ContinuousClock.now - start > timeout {
                runner.end(index, in: scenario, passed: false, since: start, detail: "Timed out")
                throw LabFailure(step: name, expected: "within \(timeout.label)", actual: "timed out")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        runner.end(index, in: scenario, passed: true, since: start)
    }

    /// Shows a question, with `content` above it, and waits for the answer: `true` for Yes or
    /// Done.
    func ask(_ title: String, detail: String, answers: Question.Answers = .yesNo, @ViewBuilder content: () -> some View) async -> Bool {
        let index = runner.begin(.ask, title, in: scenario)
        let start = ContinuousClock.now
        let view = AnyView(content())
        let answer = await withCheckedContinuation { continuation in
            runner.question = Question(title: title, detail: detail, answers: answers, content: view) { value in
                continuation.resume(returning: value)
            }
        }
        runner.end(index, in: scenario, passed: true, since: start, detail: answers == .yesNo ? (answer ? "Yes" : "No") : nil)
        return answer
    }

    /// Records a measurement, such as a count or a rate, as a step of its own.
    func metric(_ name: String, _ value: String) {
        let index = runner.begin(.metric, name, in: scenario)
        runner.end(index, in: scenario, passed: true, detail: value)
    }
}

extension Duration {
    /// "12 ms" under a second, "1.24 s" above.
    var label: String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
