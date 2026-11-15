import Records
import SwiftUI

@main
struct RecordsLabApp: App {
    @State private var runner: Runner
    /// The app's own container, which syncs with iCloud, or why it couldn't open.
    private let opened: Result<RecordContainer, any Error>

    init() {
        let opened = Result { try RecordContainer(for: Catalog.types, sync: .iCloud) }
        if case .failure(let error) = opened {
            print("LAB FAIL launch: the container didn't open: \(error)")
        }
        self.opened = opened
        _runner = State(initialValue: Runner(cloud: try? opened.get()))
    }

    var body: some Scene {
        WindowGroup {
            switch opened {
            case .success(let container):
                RootView()
                    .recordContext(container.mainContext)
                    .environment(runner)
            case .failure(let error):
                ContentUnavailableView(
                    "The records didn't open", systemImage: "externaldrive.badge.xmark",
                    description: Text(String(describing: error))
                )
            }
        }
    }
}

struct RootView: View {
    @Environment(Runner.self) private var runner

    var body: some View {
        @Bindable var runner = runner
        TabView {
            Tab("Dashboard", systemImage: "gauge.with.dots.needle.33percent") {
                DashboardView()
            }
            Tab("Scenarios", systemImage: "checklist") {
                ScenariosView()
            }
            .badge(failures)
            Tab("Catalog", systemImage: "music.note.list") {
                CatalogView()
            }
            Tab("Log", systemImage: "text.alignleft") {
                LogView()
            }
        }
        .sheet(item: $runner.question) { question in
            QuestionSheet(question: question)
                .interactiveDismissDisabled()
        }
    }

    private var failures: Int {
        runner.outcomes.values.filter { $0.status == .failed }.count
    }
}

/// A scenario's question, with whatever it wants you to look at above it.
struct QuestionSheet: View {
    let question: Question
    @Environment(Runner.self) private var runner

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let content = question.content {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(question.title, systemImage: "person.fill.questionmark")
                        .font(.headline)
                    Text(question.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch question.answers {
                    case .yesNo:
                        HStack {
                            Button {
                                runner.answer(false)
                            } label: {
                                Label("No", systemImage: "xmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            Button {
                                runner.answer(true)
                            } label: {
                                Label("Yes", systemImage: "checkmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    case .done:
                        Button {
                            runner.answer(true)
                        } label: {
                            Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
            .navigationTitle("Your turn")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
