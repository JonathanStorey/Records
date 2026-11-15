import CloudKit
import Foundation
import Testing
@testable import Records

// Level 2 of the testing layout: two simulated devices, each an in-memory container with its own
// sync object, and a stand-in server between them. One device's upload becomes the other's
// fetch, through the same calls the engine's events make. CloudKit's engine never runs here.

extension Tag {
    /// Tests of sync.
    @Tag static var sync: Self
}

private let png = Data("not really a png".utf8)

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "RecordsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Stands in for the user's private iCloud database.
///
/// A real server spots a stale upload by its change tag, which tests can't set. This one
/// remembers which version of each record it last gave each device instead, and treats an
/// upload as stale when the device last got an older version.
@MainActor
private final class StandInServer {
    private struct Entry {
        /// `nil` once deleted.
        var record: CKRecord?
        let recordType: CKRecord.RecordType
        var version: Int
    }

    private var entries: [CKRecord.ID: Entry] = [:]
    private var version = 0
    /// The version of each record each device last got.
    private var given: [ObjectIdentifier: [CKRecord.ID: Int]] = [:]
    /// The newest version each device fetched.
    private var fetched: [ObjectIdentifier: Int] = [:]
    /// Where uploaded asset files are kept, apart from either device's.
    private let files = temporaryFolder()
    /// Whether uploads fail because iCloud storage is full.
    var isFull = false

    func save(_ record: CKRecord, from device: Device) -> Result<CKRecord, CKError> {
        let id = record.recordID
        let device = ObjectIdentifier(device)
        if isFull { return .failure(CKError(.quotaExceeded)) }
        if let entry = entries[id], let known = given[device, default: [:]][id] {
            if entry.record == nil {
                // The device's copy names a record that was deleted. Once told, it uploads as new.
                given[device]?[id] = nil
                return .failure(CKError(.unknownItem))
            }
            if known != entry.version { return conflict(entry, device: device) }
        } else if let entry = entries[id], entry.record != nil {
            // The device never got this record, but another device created it.
            return conflict(entry, device: device)
        }
        version += 1
        let stored = copy(record)
        if let file = (record[RecordLink.assetKey] as? CKAsset)?.fileURL {
            let kept = files.appending(path: UUID().uuidString)
            try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: file, to: kept)
            stored[RecordLink.assetKey] = CKAsset(fileURL: kept)
        }
        entries[id] = Entry(record: stored, recordType: record.recordType, version: version)
        given[device, default: [:]][id] = version
        return .success(copy(stored))
    }

    private func conflict(_ entry: Entry, device: ObjectIdentifier) -> Result<CKRecord, CKError> {
        let current = copy(entry.record!)
        given[device, default: [:]][current.recordID] = entry.version
        return .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: current]))
    }

    func delete(_ id: CKRecord.ID, from device: Device) -> CKError? {
        guard let entry = entries[id], entry.record != nil else { return CKError(.unknownItem) }
        version += 1
        entries[id] = Entry(record: nil, recordType: entry.recordType, version: version)
        given[ObjectIdentifier(device)]?[id] = nil
        return nil
    }

    /// Every change since `device` last fetched, its own uploads included, oldest first.
    func changes(for device: Device) -> (records: [CKRecord], deletions: [(CKRecord.ID, CKRecord.RecordType)]) {
        let device = ObjectIdentifier(device)
        let since = fetched[device] ?? 0
        var records: [CKRecord] = []
        var deletions: [(CKRecord.ID, CKRecord.RecordType)] = []
        for (id, entry) in entries.sorted(by: { $0.value.version < $1.value.version }) where entry.version > since {
            if let record = entry.record {
                records.append(copy(record))
                given[device, default: [:]][id] = entry.version
            } else {
                deletions.append((id, entry.recordType))
                given[device]?[id] = nil
            }
        }
        fetched[device] = version
        return (records, deletions)
    }

    private func copy(_ record: CKRecord) -> CKRecord {
        record.copy() as! CKRecord
    }
}

/// One simulated device: an in-memory container and its sync object, with its own asset folder.
@MainActor
private final class Device {
    let container: RecordContainer
    let sync: RecordSync
    let assets: URL

    init(assets: URL = temporaryFolder()) throws {
        container = try RecordContainer(for: [Tune.self, Poster.self], url: nil, assets: assets, countsUploads: true)
        sync = RecordSync(container: container, assets: assets)
        self.assets = assets
    }

    var context: RecordContext { container.mainContext }
    var database: Database { container.database }

    func save(_ record: some Record) throws {
        context.insert(record)
        try context.save()
    }

    func delete(_ record: some Record) throws {
        context.delete(record)
        try context.save()
    }

    /// Uploads every pending record and reports the results, as the engine would.
    func send(to server: StandInServer) async throws {
        var saved: [CKRecord] = []
        var failedSaves: [(CKRecord, CKError)] = []
        var deleted: [CKRecord.ID] = []
        var failedDeletes: [(CKRecord.ID, CKError)] = []
        for change in try database.pendingChanges() {
            let id = CKRecord.ID(recordName: change.key.name, zoneID: change.key.zone.zoneID)
            if change.isDelete {
                if let error = server.delete(id, from: self) {
                    failedDeletes.append((id, error))
                } else {
                    deleted.append(id)
                }
            } else if let record = sync.recordToSend(id) {
                switch server.save(record, from: self) {
                case .success(let stored): saved.append(stored)
                case .failure(let error): failedSaves.append((record, error))
                }
            }
        }
        await sync.sent(saved: saved, failedSaves: failedSaves, deleted: deleted, failedDeletes: failedDeletes)
    }

    func fetch(from server: StandInServer) async {
        let changes = server.changes(for: self)
        await sync.received(changes.records, deletions: changes.deletions)
    }

    var hasPendingWork: Bool {
        get throws { try !database.pendingChanges().isEmpty }
    }
}

/// Two devices that both have `tune`, synced.
@MainActor
private func twoDevices(with tune: Tune) async throws -> (StandInServer, Device, Device) {
    let server = StandInServer()
    let (phone, laptop) = (try Device(), try Device())
    try phone.save(tune)
    try await phone.send(to: server)
    await phone.fetch(from: server)
    await laptop.fetch(from: server)
    return (server, phone, laptop)
}

// MARK: - Two devices

@MainActor
@Test(.tags(.sync)) func anInsertReachesTheOtherDevice() async throws {
    let tune = Tune(title: "Blue", plays: 3, released: Date(timeIntervalSinceReferenceDate: 800_000_000.25))
    let (_, phone, laptop) = try await twoDevices(with: tune)
    #expect(try laptop.context.record(id: tune.id) == tune)
    #expect(laptop.context.events.lastSynced != nil)
    #expect(try !phone.hasPendingWork && !laptop.hasPendingWork)
}

@MainActor
@Test(.tags(.sync)) func editsToDifferentFieldsOnBothDevicesMerge() async throws {
    let tune = Tune(title: "Blue", plays: 0)
    let (server, phone, laptop) = try await twoDevices(with: tune)
    var onPhone = tune
    onPhone.title = "Red"
    try phone.save(onPhone)
    var onLaptop = try #require(try laptop.context.record(id: tune.id))
    onLaptop.plays = 5
    try laptop.save(onLaptop)

    try await phone.send(to: server)
    try await laptop.send(to: server) // conflicts, merges, and stays pending
    #expect(try laptop.hasPendingWork)
    try await laptop.send(to: server)
    await phone.fetch(from: server)

    var merged = tune
    merged.title = "Red"
    merged.plays = 5
    #expect(try phone.context.record(id: tune.id) == merged)
    #expect(try laptop.context.record(id: tune.id) == merged)
    #expect(try !phone.hasPendingWork && !laptop.hasPendingWork)
}

@MainActor
@Test(.tags(.sync)) func aDeleteReachesTheOtherDevice() async throws {
    let tune = Tune(title: "Blue", plays: 0)
    let (server, phone, laptop) = try await twoDevices(with: tune)
    try phone.delete(tune)
    try await phone.send(to: server)
    await laptop.fetch(from: server)
    #expect(try laptop.context.record(id: tune.id) == nil)
    #expect(try laptop.database.rows("SELECT * FROM \"Tune\"").isEmpty)
    #expect(try phone.database.rows("SELECT * FROM \"Tune\"").isEmpty)
}

/// The edit uploads after the delete reached the server: the server can't find the record, so
/// the edit uploads it again as new, and it comes back on the deleting device.
@MainActor
@Test(.tags(.sync)) func anEditAfterTheOtherDeviceDeletedWins() async throws {
    let tune = Tune(title: "Blue", plays: 0)
    let (server, phone, laptop) = try await twoDevices(with: tune)
    try phone.delete(tune)
    var edited = tune
    edited.plays = 5
    try laptop.save(edited)

    try await phone.send(to: server)
    try await laptop.send(to: server)
    try await laptop.send(to: server)
    await phone.fetch(from: server)
    #expect(try phone.context.record(id: tune.id) == edited)
    #expect(try !phone.hasPendingWork && !laptop.hasPendingWork)
}

/// The deletion arrives before the edit uploads: the edit forgets the server's copy and uploads
/// as new.
@MainActor
@Test(.tags(.sync)) func aDeletionFetchedUnderAnEditKeepsTheEdit() async throws {
    let tune = Tune(title: "Blue", plays: 0)
    let (server, phone, laptop) = try await twoDevices(with: tune)
    try phone.delete(tune)
    try await phone.send(to: server)
    var edited = tune
    edited.plays = 5
    try laptop.save(edited)

    await laptop.fetch(from: server)
    #expect(try laptop.context.record(id: tune.id) == edited)
    try await laptop.send(to: server)
    await phone.fetch(from: server)
    #expect(try phone.context.record(id: tune.id) == edited)
}

@MainActor
@Test(.tags(.sync)) func anAssetReachesTheOtherDevice() async throws {
    let server = StandInServer()
    // Saving copies the file into the phone's own folder, which it uploads from.
    let phone = try Device()
    let laptop = try Device()
    let poster = Poster(title: "Tour", image: png)
    try phone.save(poster)
    try await phone.send(to: server)
    await laptop.fetch(from: server)

    let id = try #require(poster._image.id)
    #expect(try laptop.context.record(id: poster.id)?.title == "Tour")
    #expect(try Data(contentsOf: laptop.assets.appending(path: "\(id.uuidString).asset")) == png)
}

@MainActor
@Test(.tags(.sync)) func fullStorageIsReportedUntilAnUploadSaves() async throws {
    let server = StandInServer()
    let phone = try Device()
    server.isFull = true
    try phone.save(Tune(title: "Blue", plays: 0))
    try await phone.send(to: server)
    #expect(isStorageFull(phone) == true)
    #expect(try phone.hasPendingWork)

    server.isFull = false
    try await phone.send(to: server)
    #expect(isStorageFull(phone) == false)
    #expect(try !phone.hasPendingWork)
}

/// What the newest `.storage` entry of `device`'s events says, or `nil` when there is none.
@MainActor
private func isStorageFull(_ device: Device) -> Bool? {
    for case .storage(_, let isFull) in device.context.events.reversed() { return isFull }
    return nil
}

// MARK: - A batch that can't be written

/// A fetched batch that fails to write clears the saved state and keeps later state from being
/// saved, so the next launch fetches everything again.
@MainActor
@Test(.tags(.sync)) func aBatchThatCantBeWrittenForgetsTheSavedState() async throws {
    // The asset folder can't be created inside a file, so the asset can't be copied in.
    let blocker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try png.write(to: blocker)
    let device = try Device(assets: blocker.appending(path: "Assets", directoryHint: .isDirectory))
    await device.sync.saveState(Data("state".utf8))

    let link = CKRecord(recordType: RecordLink.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID))
    link["source"] = "Poster.image"
    link["sourceName"] = UUID().uuidString
    link["assetID"] = UUID().uuidString
    link[RecordLink.assetKey] = CKAsset(fileURL: blocker)
    let tune = CKRecord(recordType: Tune.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID))
    tune["title"] = "Blue"
    tune["plays"] = 0
    await device.sync.received([tune, link], deletions: [])

    #expect(try device.database.syncState(RecordSync.stateKey) == nil)
    #expect(try device.database.rows("SELECT * FROM \"Tune\"").isEmpty) // the whole batch rolled back
    #expect(device.context.events.lastSynced == nil)
    await device.sync.saveState(Data("later".utf8))
    #expect(try device.database.syncState(RecordSync.stateKey) == nil)
}

@MainActor
@Test(.tags(.sync)) func aRecordOfAnUnknownTypeIsSkipped() async throws {
    let device = try Device()
    let stranger = CKRecord(recordType: "Stranger", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID))
    let tune = CKRecord(recordType: Tune.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID))
    tune["title"] = "Blue"
    tune["plays"] = 0
    await device.sync.received([stranger, tune], deletions: [(stranger.recordID, "Stranger")])
    #expect(try device.database.rows("SELECT * FROM \"Tune\"").count == 1)
    #expect(device.context.events.lastSynced != nil)
}

// MARK: - Saved state

@MainActor
@Test(.tags(.sync)) func theSchemaListsEachTypeAndField() {
    #expect(RecordSync.schema(of: [Tune.recordType: Tune.self]) == "Tune(plays:integer,released:date,title:text)")
}

/// The saved state is kept while the types stay the same, and dropped when they change, so the
/// engine fetches everything again.
@MainActor
@Test(.tags(.sync)) func changedTypesDropTheSavedState() async throws {
    let device = try Device()
    let database = device.database
    #expect(try await device.sync.loadState() == nil)
    let schema = try #require(try database.syncState(RecordSync.schemaKey))
    #expect(schema == .text(RecordSync.schema(of: device.container.types)))

    // Same types: the saved state is read, so this stand-in state fails to decode.
    try database.setSyncState(.blob(Data("state".utf8)), for: RecordSync.stateKey)
    await #expect(throws: (any Error).self) { try await device.sync.loadState() }
    #expect(try database.syncState(RecordSync.stateKey) != nil)

    // Changed types: the state is dropped and the new schema saved.
    try database.setSyncState(.text("Tune(title:text)"), for: RecordSync.schemaKey)
    #expect(try await device.sync.loadState() == nil)
    #expect(try database.syncState(RecordSync.stateKey) == nil)
    #expect(try database.syncState(RecordSync.schemaKey) == schema)
}

@MainActor
@Test(.tags(.sync)) func syncStateRoundTrips() throws {
    let database = try Device().database
    try database.setSyncState(.blob(Data([1, 2, 3])), for: RecordSync.stateKey)
    #expect(try database.syncState(RecordSync.stateKey) == .blob(Data([1, 2, 3])))
    try database.setSyncState(nil, for: RecordSync.stateKey)
    #expect(try database.syncState(RecordSync.stateKey) == nil)
}

// MARK: - Pending work

@MainActor
@Test(.tags(.sync)) func pendingWorkListsNewEditedAndDeletedRecords() async throws {
    let server = StandInServer()
    let device = try Device()
    let (untouched, edited, deleted) = (Tune(title: "A", plays: 0), Tune(title: "B", plays: 0), Tune(title: "C", plays: 0))
    for tune in [untouched, edited, deleted] { try device.save(tune) }
    try await device.send(to: server)
    #expect(try !device.hasPendingWork)

    let new = Tune(title: "D", plays: 0)
    try device.save(new)
    var changed = edited
    changed.plays = 1
    try device.save(changed)
    try device.delete(deleted)
    let pending = try device.database.pendingChanges().filter { $0.key.recordType == Tune.recordType }
    let byName = Dictionary(uniqueKeysWithValues: pending.map { ($0.key.name, $0.isDelete) })
    #expect(byName == [new.id.uuidString: false, edited.id.uuidString: false, deleted.id.uuidString: true])
}

@MainActor
@Test(.tags(.sync)) func aRecordsTypeIsFoundByItsID() throws {
    let device = try Device()
    let tune = Tune(title: "Blue", plays: 0)
    try device.save(tune)
    #expect(try device.database.recordType(of: CKRecord.ID(recordName: tune.id.uuidString, zoneID: Zone.records.zoneID)) == Tune.recordType)
    #expect(try device.database.recordType(of: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID)) == nil)
}

/// A record with a base row is listed once, as a save.
@MainActor
@Test(.tags(.sync)) func anEditedRecordIsPendingOnce() async throws {
    let server = StandInServer()
    let device = try Device()
    var tune = Tune(title: "Blue", plays: 0)
    try device.save(tune)
    try await device.send(to: server)
    tune.plays = 1
    try device.save(tune)
    let pending = try device.database.pendingChanges()
    #expect(pending.count == 1 && pending.first?.isDelete == false)
}

// MARK: - Pending uploads

/// A save raises the count, a record's asset link counts with the record, and an upload the
/// server confirms brings it back to zero.
@MainActor
@Test(.tags(.sync)) func pendingUploadsCountUntilTheServerConfirms() async throws {
    let server = StandInServer()
    let phone = try Device()
    #expect(phone.context.pendingUploads == 0)
    try phone.save(Poster(title: "Tour", image: png))
    #expect(phone.context.pendingUploads == 1)
    try phone.save(Tune(title: "Blue", plays: 0))
    #expect(phone.context.pendingUploads == 2)

    try await phone.send(to: server)
    #expect(phone.context.pendingUploads == 0)
}

/// A device that opens with saves not yet uploaded counts them from the start.
@MainActor
@Test(.tags(.sync)) func aNewContextCountsWhatWaitsToUpload() throws {
    let phone = try Device()
    try phone.save(Tune(title: "Blue", plays: 0))
    #expect(RecordContext(container: phone.container).pendingUploads == 1)
}
