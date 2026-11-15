import Records
import UIKit

/// The results as plain text to paste anywhere: the device, then every scenario with its
/// result, failing step and measurements.
@MainActor
enum Report {
    static func text(for runner: Runner) -> String {
        let scenarios = Scenarios.all
        let outcomes = scenarios.compactMap { runner.outcomes[$0.id] }
        func count(_ status: Outcome.Status) -> Int { outcomes.filter { $0.status == status }.count }
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = [
            "Records Lab report",
            "Date: \(Date.now.formatted(date: .abbreviated, time: .standard))",
            "Device: \(device.model), \(device.systemName) \(device.systemVersion), Lab \(version)",
            "iCloud: \(account(of: runner))",
            "Results: \(count(.passed)) passed, \(count(.failed)) failed, \(count(.skipped)) skipped, \(scenarios.count - outcomes.count) not run",
        ]
        for group in ScenarioGroup.allCases {
            let ran = scenarios.filter { $0.group == group && runner.outcomes[$0.id] != nil }
            guard !ran.isEmpty else { continue }
            lines += ["", "== \(group.title) =="]
            for scenario in ran {
                guard let outcome = runner.outcomes[scenario.id] else { continue }
                let duration = outcome.duration.map { " (\($0.label))" } ?? ""
                lines.append("\(label(outcome.status)) \(scenario.id)\(duration)")
                if let failure = outcome.failure {
                    lines.append("  Failure: \(failure)")
                }
                for step in outcome.steps where step.kind == .metric || step.kind == .ask {
                    lines.append("  \(step.name): \(step.detail ?? "done")")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ status: Outcome.Status) -> String {
        switch status {
        case .running: "RUNNING"
        case .passed: "PASS"
        case .failed: "FAIL"
        case .skipped: "SKIP"
        }
    }

    private static func account(of runner: Runner) -> String {
        guard let events = runner.cloud?.mainContext.events else { return "the container didn't open" }
        for case .account(_, let status) in events.reversed() {
            return switch status {
            case .available: "signed in"
            case .noAccount: "not signed in"
            case .restricted: "restricted"
            case .temporarilyUnavailable: "temporarily unavailable"
            default: "unknown"
            }
        }
        return "not checked yet"
    }
}
