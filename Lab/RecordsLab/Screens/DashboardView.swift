import CloudKit
import OSLog
import Records
import SwiftUI

/// The app's own records at a glance: the iCloud account, sync, what waits to upload, and
/// buttons that change the catalog behind the scenes.
struct DashboardView: View {
    @Environment(\.recordContext) private var context
    @Environment(Runner.self) private var runner
    @State private var tables: [Inspector.Table] = []
    @State private var syncState: [String] = []
    @State private var assets: (count: Int, bytes: Int64) = (0, 0)
    @State private var busy: String?
    @State private var lastAction: String?
    @State private var failure: String?
    @State private var confirmsErase = false
    @State private var refreshing = false
    @State private var lastRefresh: Duration?

    private static let log = Logger(subsystem: "RecordsLab", category: "Data")

    var body: some View {
        NavigationStack {
            List {
                accountSection
                syncSection
                databaseSection
                dataSection
                scenariosSection
            }
            .navigationTitle("Records Lab")
            .refreshable { await refresh() }
            .task {
                while !Task.isCancelled {
                    inspect()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .confirmationDialog("Erase every record?", isPresented: $confirmsErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    perform("Erase") { try Seed.eraseAll(in: context) }
                }
            } message: {
                Text("Deletes every record here, and in iCloud once the deletes upload.")
            }
        }
    }

    // MARK: - iCloud

    private var account: CKAccountStatus? {
        for case .account(_, let status) in context.events.reversed() { return status }
        return nil
    }

    private var isStorageFull: Bool {
        for case .storage(_, let isFull) in context.events.reversed() { return isFull }
        return false
    }

    private var accountSection: some View {
        Section("iCloud") {
            accountLabel
            if isStorageFull {
                Label("iCloud storage is full. Uploads wait until there's room.", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
        }
    }

    private var accountLabel: some View {
        let (title, symbol, color): (String, String, Color) = switch account {
        case nil: ("Checking the iCloud account…", "icloud", Color.secondary)
        case .available?: ("Signed in to iCloud", "checkmark.icloud.fill", Color.green)
        case .noAccount?: ("Not signed in. Records stay on this device.", "icloud.slash", Color.orange)
        case .restricted?: ("iCloud is restricted on this device", "lock.icloud", Color.orange)
        case .temporarilyUnavailable?: ("iCloud is temporarily unavailable", "exclamationmark.icloud", Color.orange)
        default: ("Couldn't read the iCloud account", "xmark.icloud", Color.red)
        }
        return Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            LabeledContent {
                if let date = context.events.lastSaved {
                    Text(date, style: .relative)
                } else {
                    Text("Not since launch")
                }
            } label: {
                Label("Last save", systemImage: "square.and.arrow.down")
            }
            LabeledContent {
                if let date = context.events.lastSynced {
                    Text(date, style: .relative)
                } else {
                    Text("Not since launch")
                }
            } label: {
                Label("Last change from iCloud", systemImage: "icloud.and.arrow.down")
            }
            LabeledContent {
                Text(context.pendingUploads, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(context.pendingUploads == 0 ? Color.secondary : Color.orange)
            } label: {
                Label("Not yet uploaded", systemImage: context.pendingUploads == 0 ? "checkmark.icloud" : "icloud.and.arrow.up")
            }
            LabeledContent {
                Text(syncState.contains("private") ? "Saved" : "Not yet")
            } label: {
                Label("Sync engine state", systemImage: syncState.contains("private") ? "externaldrive.fill.badge.checkmark" : "externaldrive")
            }
            Button {
                Task { await refresh() }
            } label: {
                HStack {
                    Label("Refresh now", systemImage: "arrow.clockwise.icloud")
                    Spacer()
                    if refreshing {
                        ProgressView()
                    } else if let lastRefresh {
                        Text(lastRefresh.label).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .disabled(refreshing)
        } header: {
            Text("Sync")
        } footer: {
            Text("Not yet uploaded is context.pendingUploads: records with saved changes iCloud hasn't confirmed. Refreshing fetches from iCloud and uploads anything waiting. Unsaved edits stay.")
        }
    }

    private func refresh() async {
        refreshing = true
        let start = ContinuousClock.now
        await context.refresh()
        lastRefresh = ContinuousClock.now - start
        refreshing = false
        inspect()
    }

    // MARK: - Database

    private var databaseSection: some View {
        Section {
            let records = tables.reduce(0) { $0 + $1.records }
            let pending = tables.reduce(0) { $0 + $1.pending }
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    pending == 0 ? "Nothing waiting to upload" : "\(pending.formatted()) waiting to upload",
                    systemImage: pending == 0 ? "checkmark.icloud.fill" : "icloud.and.arrow.up"
                )
                .foregroundStyle(pending == 0 ? Color.green : Color.orange)
                ProgressView(value: Double(records - min(pending, records)), total: Double(max(records, 1)))
                    .tint(pending == 0 ? Color.green : Color.orange)
            }
            ForEach(tables) { table in
                HStack {
                    Label(Self.title(of: table.id), systemImage: Self.symbol(of: table.id))
                    Spacer()
                    Text(table.records, format: .number)
                        .monospacedDigit()
                    if table.pending > 0 {
                        Pill(text: table.pending.formatted(), symbol: "arrow.up", color: .orange)
                    } else if table.synced > 0 {
                        Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
                    }
                }
            }
            LabeledContent {
                Text("\(assets.count) · \(assets.bytes.formatted(.byteCount(style: .file)))")
            } label: {
                Label("Asset files", systemImage: "doc.richtext")
            }
        } header: {
            Text("Database")
        } footer: {
            Text("Read straight from the database file. A pending record is new, edited or deleted, and not yet confirmed by iCloud.")
        }
    }

    private func inspect() {
        tables = Inspector.tables()
        syncState = Inspector.syncState()
        assets = Inspector.assetFiles()
    }

    private static func title(of table: String) -> String {
        table == "RecordLink" ? "Links" : table + "s"
    }

    private static func symbol(of table: String) -> String {
        switch table {
        case "Album": "square.stack"
        case "Artist": "music.mic"
        case "Track": "music.note"
        case "Playlist": "music.note.list"
        case "Artwork": "photo.artframe"
        case "Venue": "mappin.and.ellipse"
        case "Review": "text.quote"
        case "RecordLink": "link"
        default: "tablecells"
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button {
                perform("Seed") { Seed.insertCatalog(into: context) }
            } label: {
                Label("Seed the catalog", systemImage: "leaf.fill")
            }
            Button {
                perform("Bulk") {
                    context.insert(Seed.bulkAlbum(tracks: 5_000))
                    return 5_001
                }
            } label: {
                Label("Add an album of 5,000 tracks", systemImage: "square.stack.3d.up.fill")
            }
            Button(role: .destructive) {
                confirmsErase = true
            } label: {
                Label("Erase everything", systemImage: "trash.fill")
            }
            if let busy {
                HStack {
                    ProgressView()
                    Text("\(busy)…")
                }
            }
            if let lastAction {
                Label(lastAction, systemImage: "stopwatch").foregroundStyle(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        } header: {
            Text("Data")
        } footer: {
            Text("These change the app's own records, which sync with iCloud. Scenarios use throwaway containers instead.")
        }
        .disabled(busy != nil)
    }

    /// Runs `work`, saves, and reports how many records it touched and how long it took.
    private func perform(_ name: String, _ work: @escaping @MainActor () throws -> Int) {
        busy = name
        failure = nil
        Task { @MainActor in
            // Let the spinner draw before the work holds the main thread.
            try? await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            do {
                let count = try work()
                try context.save()
                let line = "\(name): \(count.formatted()) records in \((ContinuousClock.now - start).label)"
                lastAction = line
                Self.log.notice("\(line, privacy: .public)")
            } catch {
                context.rollback()
                failure = "\(name) failed: \(error)"
                print("LAB FAIL \(name): \(error)")
                Self.log.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            busy = nil
            inspect()
        }
    }

    // MARK: - Scenarios

    private var scenariosSection: some View {
        Section("Scenarios") {
            let total = Scenarios.all.count
            let outcomes = Scenarios.all.compactMap { runner.outcomes[$0.id] }
            let passed = outcomes.filter { $0.status == .passed }.count
            let failed = outcomes.filter { $0.status == .failed }.count
            Gauge(value: Double(passed), in: 0...Double(max(total, 1))) {
                Text("Passed")
            } currentValueLabel: {
                Text("\(passed) of \(total)")
            }
            .tint(failed == 0 ? Color.green : Color.orange)
            HStack {
                Pill(text: "\(passed) passed", symbol: "checkmark.circle.fill", color: .green)
                Pill(text: "\(failed) failed", symbol: "xmark.octagon.fill", color: .red)
                Pill(text: "\(total - outcomes.count) not run", symbol: "circle.dashed", color: .gray)
            }
            if let running = runner.running, let scenario = Scenarios.all.first(where: { $0.id == running }) {
                HStack {
                    ProgressView()
                    Text("Running \(scenario.title)")
                }
            }
        }
    }
}

/// A small colored capsule with a symbol and text.
struct Pill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
