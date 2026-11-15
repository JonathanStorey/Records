import OSLog
import Records
import SwiftUI

/// The groups on the Scenarios tab, each with its own color and symbol.
enum ScenarioGroup: String, CaseIterable, Identifiable {
    case local, roundTrip, ghost, relaunch, failures, twoDevices

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Local"
        case .roundTrip: "Round trip"
        case .ghost: "Ghost"
        case .relaunch: "Relaunch"
        case .failures: "Failures"
        case .twoDevices: "Two devices"
        }
    }

    var symbol: String {
        switch self {
        case .local: "iphone"
        case .roundTrip: "arrow.triangle.2.circlepath.icloud"
        case .ghost: "person.2.wave.2"
        case .relaunch: "arrow.clockwise.circle"
        case .failures: "exclamationmark.icloud"
        case .twoDevices: "arrow.left.arrow.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .local: .blue
        case .roundTrip: .teal
        case .ghost: .purple
        case .relaunch: .orange
        case .failures: .red
        case .twoDevices: .teal
        }
    }

    /// Whether Run All includes the group. Relaunch scenarios quit the app, and two-device
    /// scenarios need you at both devices, so each runs on its own.
    var runsInBatch: Bool {
        self != .relaunch && self != .twoDevices
    }

    var summary: String {
        switch self {
        case .local: "Records on this device only, in throwaway containers. No iCloud."
        case .roundTrip: "Records sent to iCloud and read back by a second device the Lab plays. Needs iCloud, and works in a zone of its own."
        case .ghost: "A second device, played by the Lab, changes the same records in iCloud. Needs iCloud, and works in a zone of its own."
        case .relaunch: "Steps that quit the app and open it again. Each one picks up where it stopped."
        case .failures: "Limits iCloud enforces, and how sync behaves when it hits them."
        case .twoDevices: "Two devices signed in to the same iCloud account, with the catalog seeded on one and fetched on the other."
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

/// Ends a scenario that can't run here, such as one that needs the device signed out.
struct LabSkip: Error, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// A scenario that quit the app to be opened again, and what it kept for the rest of its run.
struct Resume: Codable {
    let scenario: Scenario.ID
    var values: [String: String]

    private static let key = "LabResume"

    static var saved: Resume? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Resume.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// One step of a run, as it happened.
struct Step: Identifiable, Codable {
    enum Kind: String, Codable {
        case act, check, wait, ask, metric, relaunch

        var symbol: String {
            switch self {
            case .act: "bolt.fill"
            case .check: "checkmark.seal"
            case .wait: "hourglass"
            case .ask: "person.fill.questionmark"
            case .metric: "gauge.with.dots.needle.67percent"
            case .relaunch: "arrow.clockwise.circle"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    let name: String
    var status: Outcome.Status = .running
    var duration: Duration?
    var detail: String?
}

/// A scenario's latest run.
struct Outcome: Codable {
    enum Status: String, Codable { case running, passed, failed, skipped }

    var status: Status = .running
    var steps: [Step] = []
    var duration: Duration?
    var failure: String?
}

/// A question that pauses a scenario until the user answers it.
struct Question: Identifiable {
    enum Answers { case yesNo, done, quit }

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

    /// The app's own container, which syncs with iCloud, or `nil` when it didn't open.
    let cloud: RecordContainer?

    init(cloud: RecordContainer?) {
        self.cloud = cloud
        outcomes = Self.savedOutcomes()
    }

    /// Finishes the scenario that quit the app, now that it has opened again.
    func resume() async {
        guard running == nil, let resume = Resume.saved else { return }
        // Cleared first, so a scenario that crashes the app doesn't run again at every launch.
        Resume.clear()
        guard let scenario = Scenarios.all.first(where: { $0.id == resume.scenario }) else { return }
        await perform(scenario, resumed: resume.values)
    }

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
        let passed = scenarios.filter { outcomes[$0.id]?.status == .passed }.count
        let skipped = scenarios.filter { outcomes[$0.id]?.status == .skipped }.count
        var line = "LAB SUMMARY \(passed) passed, \(failed.count) failed, \(skipped) skipped"
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
        saveOutcomes()
    }

    /// Runs `scenario`. With `resumed`, it picks up after a relaunch: its earlier steps stay,
    /// and the scenario reads what it kept from `Lab.resumed`.
    private func perform(_ scenario: Scenario, resumed: [String: String]? = nil) async {
        running = scenario.id
        if resumed == nil || outcomes[scenario.id] == nil {
            outcomes[scenario.id] = Outcome()
        }
        outcomes[scenario.id]?.status = .running
        let start = ContinuousClock.now
        var failure: String?
        var skipped: String?
        do {
            try await scenario.run(Lab(runner: self, scenario: scenario.id, resumed: resumed))
        } catch let skip as LabSkip {
            skipped = skip.reason
        } catch {
            failure = String(describing: error)
        }
        // A sync scenario works in the Lab zone. Put the app back where it was.
        if let cloud { cloud.mainContext.zone = cloud.defaultZone }
        let duration = ContinuousClock.now - start
        outcomes[scenario.id]?.duration = duration
        outcomes[scenario.id]?.failure = failure
        outcomes[scenario.id]?.status = failure != nil ? .failed : skipped != nil ? .skipped : .passed
        if let failure {
            report("LAB FAIL \(scenario.id) after \(duration.label): \(failure)", failed: true)
        } else if let skipped {
            report("LAB SKIP \(scenario.id): \(skipped)", failed: false)
        } else {
            report("LAB PASS \(scenario.id) in \(duration.label)", failed: false)
        }
        saveOutcomes()
        running = nil
    }

    // MARK: Saved results

    private static let outcomesKey = "LabOutcomes"

    /// The results so far, kept so a relaunch doesn't lose them.
    fileprivate func saveOutcomes() {
        UserDefaults.standard.set(try? JSONEncoder().encode(outcomes), forKey: Self.outcomesKey)
    }

    private static func savedOutcomes() -> [Scenario.ID: Outcome] {
        guard let data = UserDefaults.standard.data(forKey: outcomesKey),
              let outcomes = try? JSONDecoder().decode([Scenario.ID: Outcome].self, from: data)
        else { return [:] }
        // A run cut short by a quit or a crash is no longer running.
        return outcomes.mapValues { outcome in
            var outcome = outcome
            if outcome.status == .running { outcome.status = .failed }
            return outcome
        }
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
    /// What the scenario kept before it quit the app, when this run picks up after a relaunch.
    let resumed: [String: String]?

    fileprivate init(runner: Runner, scenario: Scenario.ID, resumed: [String: String]?) {
        self.runner = runner
        self.scenario = scenario
        self.resumed = resumed
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

    /// Waits until `condition`, which may reach iCloud, holds, checking every `interval`, and
    /// fails after `timeout`.
    func poll(_ name: String, every interval: Duration = .seconds(2), timeout: Duration = .seconds(90), until condition: @MainActor () async throws -> Bool) async throws {
        let index = runner.begin(.wait, name, in: scenario)
        let start = ContinuousClock.now
        while try await !condition() {
            if ContinuousClock.now - start > timeout {
                runner.end(index, in: scenario, passed: false, since: start, detail: "Timed out")
                throw LabFailure(step: name, expected: "within \(timeout.label)", actual: "timed out")
            }
            try await Task.sleep(for: interval)
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

    /// Keeps `values`, asks you to quit, and quits. When the app opens again, the scenario runs
    /// once more with `resumed` holding `values`. Cancelling fails the scenario.
    func relaunch(_ detail: String, keeping values: [String: String] = [:]) async throws -> Never {
        let index = runner.begin(.relaunch, "Quit and open the app again", in: scenario)
        let start = ContinuousClock.now
        Resume(scenario: scenario, values: values).save()
        runner.end(index, in: scenario, passed: true, detail: detail)
        runner.saveOutcomes()
        let quits = await withCheckedContinuation { continuation in
            runner.question = Question(title: "Quit and open the app again", detail: detail, answers: .quit, content: nil) { value in
                continuation.resume(returning: value)
            }
        }
        if quits { exit(0) }
        Resume.clear()
        runner.end(index, in: scenario, passed: false, since: start, detail: "Cancelled")
        throw LabFailure(step: "Quit and open the app again", expected: "the app to quit", actual: "cancelled")
    }

    /// Ends the scenario as skipped, saying why it can't run here.
    func skip(_ reason: String) throws -> Never {
        metric("Skipped", reason)
        throw LabSkip(reason: reason)
    }

    /// The app's own container, or a failure when it didn't open.
    func container() throws -> RecordContainer {
        try unwrap("The app's iCloud container opened", runner.cloud)
    }

    /// The app's own context, switched to the Lab zone until the scenario ends. Fails when the
    /// container didn't open or iCloud isn't available, saying which.
    func cloud() async throws -> RecordContext {
        let container = try container()
        let status = try await CKContainer.default().accountStatus()
        let found = switch status {
        case .available: "available"
        case .noAccount: "not signed in"
        case .restricted: "restricted"
        case .temporarilyUnavailable: "temporarily unavailable"
        default: "unknown"
        }
        try check("Signed in to iCloud", status == .available, expected: "available", actual: found)
        let context = container.mainContext
        context.zone = Ghost.zone
        return context
    }

    /// Waits until iCloud has confirmed every saved change.
    func waitForUploads(_ context: RecordContext, timeout: Duration = .seconds(60)) async throws {
        try await wait("iCloud confirms every change", timeout: timeout) { context.pendingUploads == 0 }
    }

    /// Fetches from iCloud, as pull to refresh does, and times it.
    @discardableResult
    func refresh(_ context: RecordContext) async throws -> Duration {
        try await act("Fetch from iCloud") { await context.refresh() }
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
