import OSLog
import SwiftUI

/// One entry from the unified log.
struct LogLine: Identifiable, Sendable {
    let id: Int
    let date: Date
    let level: Int
    let subsystem: String
    let category: String
    let message: String

    var isError: Bool { level >= OSLogEntryLog.Level.error.rawValue }

    var symbol: String {
        switch OSLogEntryLog.Level(rawValue: level) {
        case .fault: "xmark.octagon.fill"
        case .error: "exclamationmark.triangle.fill"
        case .notice: "bell.fill"
        case .debug: "ladybug.fill"
        default: "info.circle.fill"
        }
    }

    var color: Color {
        switch OSLogEntryLog.Level(rawValue: level) {
        case .fault, .error: .red
        case .notice: .orange
        case .debug: .gray
        default: .blue
        }
    }

    /// This launch's entries from Records and the Lab, oldest first.
    static func read() throws -> [LogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ OR subsystem == %@", "Records", "RecordsLab")
        let entries = try store.getEntries(at: store.position(date: .distantPast), matching: predicate)
        return entries.enumerated().compactMap { index, entry in
            guard let entry = entry as? OSLogEntryLog else { return nil }
            return LogLine(
                id: index, date: entry.date, level: entry.level.rawValue, subsystem: entry.subsystem,
                category: entry.category, message: entry.composedMessage
            )
        }
    }
}

/// What Records and the Lab have logged since launch, including every sync event.
struct LogView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", sync = "Sync", lab = "Lab", problems = "Problems"
        var id: Self { self }
    }

    @State private var lines: [LogLine] = []
    @State private var filter = Filter.all
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                let shown = lines.filter(matches).reversed()
                if shown.isEmpty {
                    ContentUnavailableView("Nothing logged yet", systemImage: "text.alignleft")
                }
                ForEach(shown) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: line.symbol).foregroundStyle(line.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.message)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Text("\(line.date.formatted(date: .omitted, time: .standard)) · \(line.subsystem) · \(line.category)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Log")
            .refreshable { await load() }
            .task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func matches(_ line: LogLine) -> Bool {
        switch filter {
        case .all: true
        case .sync: line.subsystem == "Records"
        case .lab: line.subsystem == "RecordsLab"
        case .problems: line.isError
        }
    }

    private func load() async {
        do {
            lines = try await Task.detached { try LogLine.read() }.value
            failure = nil
        } catch {
            failure = "Can't read the log: \(error.localizedDescription)"
        }
    }
}
