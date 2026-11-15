import CloudKit
import Foundation

/// Keeps a container in sync with the user's private iCloud database through `CKSyncEngine`.
///
/// It only routes. The engine's events go to the database functions that apply, merge,
/// acknowledge, and resolve, each batch in one transaction, and the container's contexts rebase
/// after any write that changes what they show. Pending work comes from the database's pending
/// index, so nothing is lost if the app quits before an upload.
///
/// The container creates one only for `.iCloud`, and never in an extension.
actor RecordSync: CKSyncEngineDelegate {
    let database: Database
    let types: [CKRecord.RecordType: any Record.Type]
    /// Where asset files are copied to when they arrive and read from when they upload.
    let assets: URL
    /// The zone created when there is no saved state.
    let defaultZone: Zone
    /// The container, whose contexts rebase and get events after sync writes. Weak, because the
    /// container keeps this.
    private weak var container: RecordContainer?
    /// `nil` until `start()`, and in tests.
    private var engine: CKSyncEngine?
    /// `false` once a fetched batch failed to write, so the engine's later state is never saved
    /// and the next launch fetches everything again.
    private var keepsState = true
    /// Whether the newest upload failed because iCloud storage is full.
    private var isStorageFull = false
    /// Whether `start()` has run, so it runs once.
    private var isStarted = false

    /// The `_SyncState` key of the engine's state.
    static let stateKey = "private"
    /// The `_SyncState` key of the registered types and fields the state was fetched with.
    static let schemaKey = "schema"

    init(container: RecordContainer, assets: URL) {
        database = container.database
        types = container.types
        defaultZone = container.defaultZone
        self.assets = assets
        self.container = container
    }

    // MARK: - Starting

    /// Creates the engine from the saved state, adds the work waiting to upload, and reports the
    /// account's status. The engine then fetches and sends on its own. Runs once. A later call,
    /// such as `refresh()` arriving first, returns once the engine exists.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        do {
            startEngine(with: try loadState())
        } catch {
            syncLog.error("Sync couldn't read its saved state: \(error.localizedDescription, privacy: .public)")
            startEngine(with: nil)
        }
        readPendingWork()
        await reportAccountStatus()
    }

    /// Creates the engine. With no state, the engine fetches everything, and the default zone is
    /// created first.
    private func startEngine(with state: CKSyncEngine.State.Serialization?) {
        let configuration = CKSyncEngine.Configuration(
            database: CKContainer.default().privateCloudDatabase, stateSerialization: state, delegate: self
        )
        let engine = CKSyncEngine(configuration)
        if state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: defaultZone.zoneID))])
        }
        self.engine = engine
        keepsState = true
    }

    /// The engine's saved state, or `nil` when there is none or the registered types or fields
    /// changed since it was saved. Then the engine fetches everything again, so a field a newer
    /// version of the app added is filled in from records fetched before.
    func loadState() throws -> CKSyncEngine.State.Serialization? {
        let schema = SQLValue.text(Self.schema(of: types))
        guard try database.syncState(Self.schemaKey) == schema else {
            try database.transaction {
                try database.setSyncState(nil, for: Self.stateKey)
                try database.setSyncState(schema, for: Self.schemaKey)
            }
            return nil
        }
        guard case .blob(let data) = try database.syncState(Self.stateKey) else { return nil }
        return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    /// Each record type with its fields and how they are stored, sorted, such as
    /// `Tune(plays:integer,title:text)`.
    static func schema(of types: [CKRecord.RecordType: any Record.Type]) -> String {
        types.keys.sorted().map { recordType in
            let fields = types[recordType]!.schema.fields.map { "\($0.key):\($0.kind.rawValue)" }.sorted()
            return "\(recordType)(\(fields.joined(separator: ",")))"
        }.joined(separator: ";")
    }

    /// Saves the engine's state, unless a fetched batch failed to write this session.
    func saveState(_ data: Data) {
        guard keepsState else { return }
        do {
            try database.setSyncState(.blob(data), for: Self.stateKey)
        } catch {
            syncLog.error("Sync couldn't save its state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Hands the engine every record waiting to upload, read from the pending index. Called at
    /// start, after each save, and after anything that leaves records to upload again.
    func readPendingWork() {
        guard let engine else { return }
        do {
            let changes = try database.pendingChanges().filter { $0.key.zone.ownerName == CKCurrentUserDefaultName }
            var added: [CKSyncEngine.PendingRecordZoneChange] = []
            var replaced: [CKSyncEngine.PendingRecordZoneChange] = []
            for change in changes {
                let id = CKRecord.ID(recordName: change.key.name, zoneID: change.key.zone.zoneID)
                added.append(change.isDelete ? .deleteRecord(id) : .saveRecord(id))
                replaced.append(change.isDelete ? .saveRecord(id) : .deleteRecord(id))
            }
            // A record deleted since its save was added, or saved since its deletion was, keeps
            // only its newest change.
            engine.state.remove(pendingRecordZoneChanges: replaced)
            engine.state.add(pendingRecordZoneChanges: added)
        } catch {
            syncLog.error("Sync couldn't read the records to upload: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches the server's changes and returns once they are written, then sends anything
    /// waiting to upload. A failure is logged, and the engine tries again on its own.
    func refresh() async {
        await start()
        guard let engine else { return }
        readPendingWork()
        do {
            try await engine.fetchChanges()
            if !engine.state.pendingRecordZoneChanges.isEmpty || !engine.state.pendingDatabaseChanges.isEmpty {
                try await engine.sendChanges()
            }
        } catch {
            syncLog.info("Refresh didn't finish: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Appends the account's status to the contexts' events. With `rebasing`, the contexts
    /// rebase first, because the records changed.
    private func reportAccountStatus(rebasing: Bool = false) async {
        let status = (try? await CKContainer.default().accountStatus()) ?? .couldNotDetermine
        await container?.syncDidWrite(.account(.now, status), rebasing: rebasing)
    }

    // MARK: - Engine events

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine replaced after an account change may still report. Only the current one counts.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            do {
                saveState(try JSONEncoder().encode(update.stateSerialization))
            } catch {
                syncLog.error("Sync couldn't encode its state: \(error.localizedDescription, privacy: .public)")
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                readPendingWork()
                await reportAccountStatus()
            case .signOut, .switchAccounts:
                await resetAccount()
            @unknown default:
                await reportAccountStatus()
            }
        case .fetchedDatabaseChanges(let changes):
            await zonesDeleted(changes.deletions.map { ($0.zoneID, $0.reason) })
        case .fetchedRecordZoneChanges(let changes):
            await received(changes.modifications.map(\.record), deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
        case .sentRecordZoneChanges(let changes):
            await sent(
                saved: changes.savedRecords,
                failedSaves: changes.failedRecordSaves.map { ($0.record, $0.error) },
                deleted: changes.deletedRecordIDs,
                failedDeletes: changes.failedRecordDeletes.map { ($0.key, $0.value) }
            )
        case .sentDatabaseChanges(let changes):
            for failure in changes.failedZoneSaves {
                syncLog.error("Sync couldn't create zone \(failure.zone.zoneID.zoneName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        var changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let stale = changes.filter { isStale($0) }
        if !stale.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: stale)
            changes.removeAll { stale.contains($0) }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [self] recordID in
            guard let record = recordToSend(recordID) else {
                // Nothing to save: the record synced or was deleted since it was added.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }

    /// Whether `change` deletes a record that is no longer deleted here. A newer edit from another
    /// device brings a deleted record back when it arrives before the deletion uploads, and
    /// sending the deletion then would delete the record the merge kept.
    nonisolated func isStale(_ change: CKSyncEngine.PendingRecordZoneChange) -> Bool {
        guard case .deleteRecord(let recordID) = change else { return false }
        do {
            guard let recordType = try database.recordType(of: recordID),
                  let row = try database.currentRow(of: Database.key(of: recordID, recordType: recordType))
            else { return false }
            return row["_deleted"] != .integer(1)
        } catch {
            return false
        }
    }

    /// The record to upload for `recordID`, or `nil` when it has nothing to save.
    nonisolated func recordToSend(_ recordID: CKRecord.ID) -> CKRecord? {
        do {
            guard let recordType = try database.recordType(of: recordID), let type = types[recordType] else { return nil }
            return try database.recordToSend(for: recordID, schema: type.schema, assets: assets)
        } catch {
            syncLog.error("Sync couldn't read \(recordID.recordName, privacy: .public) to upload: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Writing

    /// Writes fetched records and deletions in one transaction, then rebases the contexts and
    /// appends `.synced`.
    ///
    /// A record of a type this app doesn't register, or one this app can't read because a field
    /// it needs is missing or holds another type, is skipped and logged, and never written. If the batch can't be written, the saved state is cleared and later state isn't
    /// saved this session, because the engine counts the batch as received. The next launch
    /// fetches everything again, which changes nothing already here.
    func received(_ records: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) async {
        copyAssets(of: records)
        do {
            try database.transaction {
                for record in records where Self.isOwn(record.recordID.zoneID) {
                    guard let type = types[record.recordType] else {
                        syncLog.info("Skipped a \(record.recordType, privacy: .public): the app doesn't register that type")
                        continue
                    }
                    guard Self.isReadable(record, as: type, else: "Skipped") else { continue }
                    try database.apply(record, schema: type.schema, assets: assets)
                }
                for (recordID, recordType) in deletions where types[recordType] != nil && Self.isOwn(recordID.zoneID) {
                    try database.applyDeletion(of: recordID, recordType: recordType)
                }
            }
        } catch {
            syncLog.fault("Sync couldn't write fetched changes, so the next launch fetches everything: \(error.localizedDescription, privacy: .public)")
            keepsState = false
            try? database.setSyncState(nil, for: Self.stateKey)
            return
        }
        await container?.syncDidWrite(.synced(.now), rebasing: true)
    }

    /// Whether this app can read `record` as `type`: every field it needs is there, holding the
    /// type it expects. When it can't, logs why after `action`.
    private static func isReadable(_ record: CKRecord, as type: any Record.Type, else action: String) -> Bool {
        do {
            _ = try CKRecordDecoder().decode(type, from: record)
            return true
        } catch {
            syncLog.error("\(action, privacy: .public) \(record.recordType, privacy: .public) \(record.recordID.recordName, privacy: .public): this app can't read it: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Writes what the server did with an upload in one transaction, hands the engine every
    /// record that still has work to upload, and returns those changes.
    ///
    /// A merged conflict rebases the contexts and appends `.synced`. Full storage appends
    /// `.storage(isFull: true)`, and the next upload that saves appends `isFull: false`.
    @discardableResult
    func sent(
        saved: [CKRecord], failedSaves: [(CKRecord, CKError)], deleted: [CKRecord.ID],
        failedDeletes: [(CKRecord.ID, CKError)]
    ) async -> [CKSyncEngine.PendingRecordZoneChange] {
        var again: [CKSyncEngine.PendingRecordZoneChange] = []
        var merged = false
        var isFull = false
        var missingZones: Set<CKRecordZone.ID> = []
        copyAssets(of: failedSaves.compactMap { $0.1.serverRecord })
        do {
            try database.transaction {
                func failed(_ recordID: CKRecord.ID, _ recordType: CKRecord.RecordType?, _ error: CKError) throws {
                    guard let recordType, let type = types[recordType] else { return }
                    // Merging a server copy this app can't read would write it. The upload stops
                    // instead, so it doesn't fail the same way again and again.
                    if let server = error.serverRecord, error.code == .serverRecordChanged,
                       !Self.isReadable(server, as: type, else: "Kept this device's copy and stopped uploading") {
                        return
                    }
                    if try database.resolve(error, for: recordID, schema: type.schema, assets: assets) {
                        again += try pendingChange(recordID, recordType: recordType)
                    }
                    switch error.code {
                    case .serverRecordChanged: merged = true
                    case .quotaExceeded: isFull = true
                    case .zoneNotFound: missingZones.insert(recordID.zoneID)
                    default: break
                    }
                }
                for record in saved {
                    guard let type = types[record.recordType] else { continue }
                    try database.acknowledge(saved: record, schema: type.schema)
                    again += try pendingChange(record.recordID, recordType: record.recordType)
                }
                for recordID in deleted {
                    guard let recordType = try database.recordType(of: recordID) else { continue }
                    try database.acknowledge(deleted: recordID, recordType: recordType)
                    again += try pendingChange(recordID, recordType: recordType)
                }
                for (record, error) in failedSaves {
                    try failed(record.recordID, record.recordType, error)
                }
                for (recordID, error) in failedDeletes {
                    try failed(recordID, try database.recordType(of: recordID), error)
                }
            }
        } catch {
            syncLog.error("Sync couldn't write an upload's results: \(error.localizedDescription, privacy: .public)")
            readPendingWork()
            return []
        }
        engine?.state.add(pendingRecordZoneChanges: again)
        if !missingZones.isEmpty {
            engine?.state.add(pendingDatabaseChanges: missingZones.map { .saveZone(CKRecordZone(zoneID: $0)) })
        }
        if merged {
            await container?.syncDidWrite(.synced(.now), rebasing: true)
        }
        if isFull != isStorageFull, isFull || !saved.isEmpty {
            isStorageFull = isFull
            await container?.syncDidWrite(.storage(.now, isFull: isFull), rebasing: false)
        }
        await container?.uploadsDidChange()
        return again
    }

    /// Copies the asset files of `records` into the asset folder before their transaction, so
    /// large files never hold the database lock while the app reads. A copy that fails here is
    /// tried again inside the transaction, where it fails the batch.
    private func copyAssets(of records: [CKRecord]) {
        for record in records where Self.isOwn(record.recordID.zoneID) {
            try? database.copyAsset(of: record, into: assets)
        }
    }

    /// The change that uploads `recordID`'s work, when it has any.
    private func pendingChange(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType) throws -> [CKSyncEngine.PendingRecordZoneChange] {
        let key = Database.key(of: recordID, recordType: recordType)
        guard try database.isPending(key) else { return [] }
        return try database.currentRow(of: key)?["_deleted"] == .integer(1) ? [.deleteRecord(recordID)] : [.saveRecord(recordID)]
    }

    /// Applies zones the server deleted. A deleted or purged zone loses its records. A zone whose
    /// encrypted data was reset is created again, and its records upload again as new.
    func zonesDeleted(_ deletions: [(CKRecordZone.ID, CKDatabase.DatabaseChange.Deletion.Reason)]) async {
        let deletions = deletions.filter { Self.isOwn($0.0) }
        guard !deletions.isEmpty else { return }
        var reset: [CKRecordZone.ID] = []
        do {
            try database.transaction {
                for (zoneID, reason) in deletions {
                    switch reason {
                    case .deleted, .purged:
                        try database.removeRecords(in: Zone(zoneID))
                    case .encryptedDataReset:
                        try database.clearSystemFields(in: Zone(zoneID))
                        reset.append(zoneID)
                    @unknown default:
                        syncLog.error("Zone \(zoneID.zoneName, privacy: .public) was deleted for a reason Records doesn't know")
                    }
                }
            }
        } catch {
            syncLog.error("Sync couldn't apply deleted zones: \(error.localizedDescription, privacy: .public)")
            return
        }
        if !reset.isEmpty {
            engine?.state.add(pendingDatabaseChanges: reset.map { .saveZone(CKRecordZone(zoneID: $0)) })
            readPendingWork()
        }
        await container?.syncDidWrite(.synced(.now), rebasing: true)
    }

    /// After the user signed out or switched accounts: removes every record, so one person's
    /// records never upload into the next account, and starts a new engine with no state.
    private func resetAccount() async {
        do {
            try database.transaction {
                try database.removeAllRecords()
                try database.setSyncState(nil, for: Self.stateKey)
            }
        } catch {
            syncLog.fault("Sync couldn't remove the previous account's records: \(error.localizedDescription, privacy: .public)")
        }
        isStorageFull = false
        startEngine(with: nil)
        await reportAccountStatus(rebasing: true)
    }

    /// Whether `zoneID` is a zone of the current user that Records can use.
    private static func isOwn(_ zoneID: CKRecordZone.ID) -> Bool {
        zoneID.ownerName == CKCurrentUserDefaultName && Zone.isAllowed(zoneID.zoneName)
    }
}
