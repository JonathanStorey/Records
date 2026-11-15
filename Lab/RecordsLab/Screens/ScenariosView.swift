import SwiftUI

/// The scenarios, one group at a time, each group in its own color.
struct ScenariosView: View {
    @Environment(Runner.self) private var runner
    @State private var group = ScenarioGroup.local

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Group", selection: $group) {
                        ForEach(ScenarioGroup.allCases) { group in
                            Image(systemName: group.symbol)
                                .accessibilityLabel(group.title)
                                .tag(group)
                        }
                    }
                    .pickerStyle(.segmented)
                    GroupHeader(group: group, scenarios: scenarios)
                }
                if scenarios.isEmpty {
                    ContentUnavailableView(
                        "Coming in a later build", systemImage: group.symbol,
                        description: Text(group.summary)
                    )
                } else {
                    Section("Scenarios") {
                        ForEach(scenarios) { scenario in
                            NavigationLink(value: scenario.id) {
                                ScenarioRow(scenario: scenario, outcome: runner.outcomes[scenario.id])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scenarios")
            .navigationDestination(for: Scenario.ID.self) { id in
                if let scenario = Scenarios.all.first(where: { $0.id == id }) {
                    ScenarioDetail(scenario: scenario)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: Report.text(for: runner)) {
                        Label("Report", systemImage: "square.and.arrow.up")
                    }
                    .disabled(runner.outcomes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Run every scenario", systemImage: "play.fill") {
                            Task { await runner.runAll(Scenarios.all.filter { $0.group.runsInBatch }) }
                        }
                        Button("Clear results", systemImage: "xmark.circle") {
                            runner.clear()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(runner.running != nil)
                }
            }
        }
    }

    private var scenarios: [Scenario] {
        Scenarios.all.filter { $0.group == group }
    }
}

/// A group's title, summary, progress and Run All button.
struct GroupHeader: View {
    let group: ScenarioGroup
    let scenarios: [Scenario]
    @Environment(Runner.self) private var runner

    var body: some View {
        let outcomes = scenarios.compactMap { runner.outcomes[$0.id] }
        let passed = outcomes.filter { $0.status == .passed }.count
        let failed = outcomes.filter { $0.status == .failed }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: group.symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(group.color.gradient, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading) {
                    Text(group.title).font(.title3.bold())
                    Text(group.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !scenarios.isEmpty {
                ProgressView(value: Double(outcomes.count - outcomes.filter { $0.status == .running }.count), total: Double(scenarios.count))
                    .tint(failed > 0 ? Color.red : group.color)
                HStack {
                    Pill(text: "\(passed) passed", symbol: "checkmark.circle.fill", color: .green)
                    if failed > 0 {
                        Pill(text: "\(failed) failed", symbol: "xmark.octagon.fill", color: .red)
                    }
                    Spacer()
                    if group.runsInBatch {
                        Button {
                            Task { await runner.runAll(scenarios) }
                        } label: {
                            Label("Run all", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(group.color)
                        .disabled(runner.running != nil)
                    }
                }
                if let progress = runner.progress {
                    Text("Running \(progress.done + 1) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusIcon: View {
    let outcome: Outcome?

    var body: some View {
        switch outcome?.status {
        case .running?:
            ProgressView()
        case .passed?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed?:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped?:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

struct ScenarioRow: View {
    let scenario: Scenario
    let outcome: Outcome?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scenario.symbol)
                .foregroundStyle(scenario.group.color)
                .frame(width: 32, height: 32)
                .background(scenario.group.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.title).font(.headline)
                Text(scenario.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let failure = outcome?.failure {
                    Text(failure)
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusIcon(outcome: outcome)
                if let duration = outcome?.duration {
                    Text(duration.label)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A scenario's summary and every step of its latest run.
struct ScenarioDetail: View {
    let scenario: Scenario
    @Environment(Runner.self) private var runner

    var body: some View {
        let outcome = runner.outcomes[scenario.id]
        List {
            Section {
                Text(scenario.summary)
                HStack {
                    StatusIcon(outcome: outcome)
                    if let duration = outcome?.duration {
                        Text(duration.label).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await runner.run(scenario) }
                    } label: {
                        Label(outcome == nil ? "Run" : "Run again", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(scenario.group.color)
                    .disabled(runner.running != nil)
                }
            }
            if let failure = outcome?.failure {
                Section("Failure") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            if let steps = outcome?.steps, !steps.isEmpty {
                Section("Steps") {
                    ForEach(steps) { step in
                        StepRow(step: step)
                    }
                }
            }
        }
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: step.kind.symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(step.status == .failed ? Color.red : Color.secondary)
                }
            }
            Spacer()
            if let duration = step.duration {
                Text(duration.label)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            switch step.status {
            case .running: ProgressView()
            case .passed: Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus").foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch step.status {
        case .failed: .red
        case .running, .skipped: .secondary
        case .passed: step.kind == .metric ? .purple : .accentColor
        }
    }
}
