import CloudKit
import Foundation
import Testing
@testable import Records

// Each rule in the sync plan's tables is one test here. The server is played by hand-built
// `CKRecord` values, and the database is in memory.

@Record
struct Tune: Equatable {
    var title: String
    var plays: Int
    var released: Date?
}

/// An in-memory database, a context on it, and a temporary asset folder.
@MainActor
private struct Store {
    let container: RecordContainer
    let assets = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    init() throws {
        container = try RecordContainer(for: [Tune.self], url: nil)
    }

    var database: Database { container.database }
    var context: RecordContext { container.mainContext }

    /// The current and base rows of the record named `name`.
    func rows(_ name: String, type: CKRecord.RecordType = Tune.recordType) throws -> (current: [String: SQLValue]?, base: [String: SQLValue]?) {
        let rows = try database.rows("SELECT * FROM \(quoted(type)) WHERE \"_name\" = ?", [.text(name)])
        return (rows.first { $0["_isCurrent"] == .integer(1) }, rows.first { $0["_isCurrent"] == .integer(0) })
    }

    func isPending(_ name: String, type: CKRecord.RecordType = Tune.recordType) throws -> Bool {
        try database.isPending(RecordKey(recordType: type, name: name, zone: .records))
    }

    /// Applies the server's copy of a tune.
    func fetch(_ record: CKRecord) throws {
        try database.apply(record, schema: Tune.schema, assets: assets)
    }

    /// A tune saved by this device and synced: the server copy has been applied.
    func syncedTune(title: String = "Blue", plays: Int = 0) throws -> Tune {
        let tune = Tune(title: title, plays: plays)
        try fetch(server(tune.id.uuidString, title: title, plays: plays))
        return tune
    }

    /// Saves `tune` through the context, as the app would.
    func save(_ tune: Tune) throws {
        context.insert(tune)
        try context.save()
    }

    func delete(_ tune: Tune) throws {
        context.delete(tune)
        try context.save()
    }
}

/// The server's copy of a tune.
private func server(_ name: String, title: String, plays: Int, zone: Zone = .records) -> CKRecord {
    let record = CKRecord(recordType: Tune.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zone.zoneID))
    record["title"] = title
    record["plays"] = plays
    return record
}

private func recordID(_ name: String, zone: Zone = .records) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone.zoneID)
}

private func title(_ row: [String: SQLValue]?) -> String? {
    if case .text(let title) = row?["title"] { title } else { nil }
}

private func plays(_ row: [String: SQLValue]?) -> Int64? {
    if case .integer(let plays) = row?["plays"] { plays } else { nil }
}

// MARK: - The merge

private let base: [String: SQLValue] = ["title": .text("Blue"), "plays": .integer(1), "released": .null]

@Test func aFieldOursLeftTakesTheirs() {
    let merged = Database.merged(base: base, ours: base, theirs: base.merging(["title": .text("Red")]) { $1 }, schema: Tune.schema)
    #expect(merged["title"] == .text("Red"))
}

@Test func aFieldTheirsLeftKeepsOurs() {
    let merged = Database.merged(base: base, ours: base.merging(["title": .text("Mine")]) { $1 }, theirs: base, schema: Tune.schema)
    #expect(merged["title"] == .text("Mine"))
}

@Test func aFieldBothChangedToOneValueTakesIt() {
    let same = base.merging(["plays": .integer(5)]) { $1 }
    #expect(Database.merged(base: base, ours: same, theirs: same, schema: Tune.schema)["plays"] == .integer(5))
}

@Test func aFieldBothChangedDifferentlyKeepsOurs() {
    let merged = Database.merged(
        base: base, ours: base.merging(["plays": .integer(2)]) { $1 },
        theirs: base.merging(["plays": .integer(3)]) { $1 }, schema: Tune.schema
    )
    #expect(merged["plays"] == .integer(2))
}

@Test func differentFieldsChangedOnEachSideBothSurvive() {
    let merged = Database.merged(
        base: base, ours: base.merging(["title": .text("Mine")]) { $1 },
        theirs: base.merging(["plays": .integer(9)]) { $1 }, schema: Tune.schema
    )
    #expect(merged["title"] == .text("Mine") && merged["plays"] == .integer(9))
}

@Test func withNoBaseEveryDifferenceKeepsOurs() {
    let merged = Database.merged(
        base: nil, ours: base, theirs: ["title": .text("Red"), "plays": .integer(4), "released": .null], schema: Tune.schema
    )
    #expect(merged == base)
}

/// A date goes to CloudKit as a `Double`, which CloudKit keeps to the last bit, so the server's
/// copy matches the row exactly and an acknowledged upload settles the record.
@MainActor
@Test func aDateRoundTripsExactlyThroughCloudKit() throws {
    let store = try Store()
    let released = Date(timeIntervalSinceReferenceDate: 800_000_000.999_999_9)
    let tune = Tune(title: "Blue", plays: 0, released: released)
    try store.save(tune)
    let sent = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    #expect((sent["released"] as? NSNumber)?.doubleValue == released.timeIntervalSinceReferenceDate)
    try store.database.acknowledge(saved: sent, schema: Tune.schema)
    #expect(try !store.isPending(tune.id.uuidString))
    #expect(try store.context.record(id: tune.id)?.released == released)
}

/// A date field CloudKit typed as a date, such as one written by another tool, still reads.
@Test func aCloudKitDateStillDecodes() throws {
    let record = server(UUID().uuidString, title: "Blue", plays: 0)
    let released = Date(timeIntervalSince1970: 1_700_000_000.123)
    record["released"] = released
    #expect(try Tune.schema.values(of: record)["released"] == .real(released.timeIntervalSinceReferenceDate))
}

// MARK: - Links and assets merge whole

private func assetLink(_ assetID: String?, target: String? = nil) -> [String: SQLValue] {
    ["source": .text("Tune.cover"), "sourceName": .text("A"), "targetName": target.map(SQLValue.text) ?? .null,
     "assetID": assetID.map(SQLValue.text) ?? .null]
}

@Test func anAssetBothSidesReplacedKeepsOursWhole() {
    let merged = Database.merged(base: assetLink("1"), ours: assetLink("2"), theirs: assetLink("3"), schema: RecordLink.schema)
    #expect(merged == assetLink("2"))
}

@Test func anAssetOursLeftTakesTheirs() {
    let merged = Database.merged(base: assetLink("1"), ours: assetLink("1"), theirs: assetLink("3"), schema: RecordLink.schema)
    #expect(merged == assetLink("3"))
}

@Test func aLinkNeverMixesTheTwoSides() {
    // Ours moved the target, theirs changed the asset: one side wins whole.
    let merged = Database.merged(
        base: assetLink("1", target: "T"), ours: assetLink("1", target: "U"), theirs: assetLink("3", target: "T"),
        schema: RecordLink.schema
    )
    #expect(merged == assetLink("1", target: "U"))
}

// MARK: - A fetched record

@MainActor
@Test func aFetchedRecordWithNoRowIsInsertedSynced() throws {
    let store = try Store()
    let tune = try store.syncedTune(title: "Blue", plays: 3)
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Blue" && plays(rows.current) == 3)
    #expect(rows.current?["_systemFields"] != .null && rows.base == nil)
    #expect(try !store.isPending(tune.id.uuidString))
    #expect(try store.context.record(id: tune.id)?.title == "Blue")
}

@MainActor
@Test func aFetchedRecordReplacesASyncedRow() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.fetch(server(tune.id.uuidString, title: "Red", plays: 7))
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Red" && plays(rows.current) == 7)
    #expect(try !store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aFetchedRecordMergesWithAnEdit() throws {
    let store = try Store()
    var tune = try store.syncedTune(title: "Blue", plays: 0)
    tune.title = "Mine"
    try store.save(tune)
    try store.fetch(server(tune.id.uuidString, title: "Blue", plays: 4))
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Mine" && plays(rows.current) == 4)
    // Theirs is the new base, so the record still has our title to upload.
    #expect(title(rows.base) == "Blue" && plays(rows.base) == 4)
    #expect(try store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aMergeThatEqualsTheirsLeavesTheRecordSynced() throws {
    let store = try Store()
    var tune = try store.syncedTune(title: "Blue")
    tune.title = "Red"
    try store.save(tune)
    try store.fetch(server(tune.id.uuidString, title: "Red", plays: 0))
    #expect(try store.rows(tune.id.uuidString).base == nil)
    #expect(try !store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aFetchedRecordWithTheIDOfANewOneKeepsOurs() throws {
    let store = try Store()
    let tune = Tune(title: "Mine", plays: 1)
    try store.save(tune)
    try store.fetch(server(tune.id.uuidString, title: "Theirs", plays: 2))
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Mine" && plays(rows.current) == 1)
    #expect(title(rows.base) == "Theirs")
    #expect(try store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aFetchedEditBringsBackARecordDeletedHere() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    #expect(try store.isPending(tune.id.uuidString))
    try store.fetch(server(tune.id.uuidString, title: "Red", plays: 2))
    let rows = try store.rows(tune.id.uuidString)
    #expect(rows.current?["_deleted"] == .integer(0) && title(rows.current) == "Red")
    #expect(try !store.isPending(tune.id.uuidString))
}

@MainActor
@Test func applyingTheSameRecordTwiceChangesNothing() throws {
    let store = try Store()
    var tune = try store.syncedTune()
    tune.title = "Mine"
    try store.save(tune)
    let theirs = server(tune.id.uuidString, title: "Blue", plays: 4)
    try store.fetch(theirs)
    let once = try store.rows(tune.id.uuidString)
    try store.fetch(theirs)
    let twice = try store.rows(tune.id.uuidString)
    #expect(once.current == twice.current && once.base == twice.base)
}

@MainActor
@Test func aFetchedRecordThatFailsToDecodeThrowsAndWritesNothing() throws {
    let store = try Store()
    let record = server(UUID().uuidString, title: "Blue", plays: 0)
    record["plays"] = "many"
    #expect(throws: CKRecordDecodingError.typeMismatch(field: "plays")) { try store.fetch(record) }
    #expect(try store.rows(record.recordID.recordName).current == nil)
}

// MARK: - A fetched deletion

@MainActor
@Test func aFetchedDeletionRemovesASyncedRecord() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.database.applyDeletion(of: recordID(tune.id.uuidString), recordType: Tune.recordType)
    #expect(try store.rows(tune.id.uuidString).current == nil)
}

@MainActor
@Test func aFetchedDeletionLosesToAnEdit() throws {
    let store = try Store()
    var tune = try store.syncedTune()
    tune.title = "Mine"
    try store.save(tune)
    try store.database.applyDeletion(of: recordID(tune.id.uuidString), recordType: Tune.recordType)
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Mine" && rows.current?["_systemFields"] == .null && rows.base == nil)
    #expect(try store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aFetchedDeletionOfARecordDeletedHereRemovesIt() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    try store.database.applyDeletion(of: recordID(tune.id.uuidString), recordType: Tune.recordType)
    #expect(try store.rows(tune.id.uuidString).current == nil)
}

@MainActor
@Test func aFetchedDeletionWithNoRowDoesNothing() throws {
    let store = try Store()
    try store.database.applyDeletion(of: recordID(UUID().uuidString), recordType: Tune.recordType)
    #expect(try store.database.rows("SELECT * FROM \"Tune\"").isEmpty)
}

@MainActor
@Test func aFetchedDeletionKeepsANewRecordWithTheSameID() throws {
    let store = try Store()
    let tune = Tune(title: "Mine", plays: 1)
    try store.save(tune)
    try store.database.applyDeletion(of: recordID(tune.id.uuidString), recordType: Tune.recordType)
    #expect(title(try store.rows(tune.id.uuidString).current) == "Mine")
    #expect(try store.isPending(tune.id.uuidString))
}

// MARK: - Sending

@MainActor
@Test func aSyncedRecordHasNothingToSend() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    #expect(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets) == nil)
}

@MainActor
@Test func aNewRecordIsSentWithEveryField() throws {
    let store = try Store()
    let tune = Tune(title: "Blue", plays: 2)
    try store.save(tune)
    let record = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    #expect(record.recordID == recordID(tune.id.uuidString))
    #expect(record["title"] as? String == "Blue" && (record["plays"] as? NSNumber)?.intValue == 2)
}

@MainActor
@Test func anEditedRecordIsSentFromTheServerCopy() throws {
    let store = try Store()
    var tune = try store.syncedTune(title: "Blue")
    tune.title = "Mine"
    try store.save(tune)
    let record = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    #expect(record["title"] as? String == "Mine")
}

@MainActor
@Test func aDeletedRecordIsNotSentAsASave() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    #expect(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets) == nil)
}

@MainActor
@Test func aMissingRecordIsNotSent() throws {
    let store = try Store()
    #expect(try store.database.recordToSend(for: recordID(UUID().uuidString), schema: Tune.schema, assets: store.assets) == nil)
}

// MARK: - Acknowledging

@MainActor
@Test func anAcknowledgedSaveSyncsTheRecord() throws {
    let store = try Store()
    let tune = Tune(title: "Blue", plays: 2)
    try store.save(tune)
    let sent = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    try store.database.acknowledge(saved: sent, schema: Tune.schema)
    let rows = try store.rows(tune.id.uuidString)
    #expect(rows.current?["_systemFields"] != .null && rows.base == nil)
    #expect(try !store.isPending(tune.id.uuidString))
}

@MainActor
@Test func anEditDuringTheUploadStaysPending() throws {
    let store = try Store()
    var tune = Tune(title: "Blue", plays: 2)
    try store.save(tune)
    let sent = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    tune.title = "Mine"
    try store.save(tune)
    try store.database.acknowledge(saved: sent, schema: Tune.schema)
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Mine" && title(rows.base) == "Blue")
    #expect(rows.current?["_systemFields"] != .null && rows.current?["_systemFields"] == rows.base?["_systemFields"])
    #expect(try store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aDeleteDuringTheUploadStaysPending() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    var edited = tune
    edited.title = "Mine"
    try store.save(edited)
    let sent = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    try store.delete(tune)
    try store.database.acknowledge(saved: sent, schema: Tune.schema)
    #expect(try store.rows(tune.id.uuidString).current?["_deleted"] == .integer(1))
    #expect(try store.isPending(tune.id.uuidString))
}

@MainActor
@Test func aNewRecordDeletedDuringItsUploadIsDeletedOnTheServerToo() throws {
    let store = try Store()
    let tune = Tune(title: "Blue", plays: 2)
    try store.save(tune)
    let sent = try #require(try store.database.recordToSend(for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    try store.delete(tune)
    #expect(try store.rows(tune.id.uuidString).current == nil)
    try store.database.acknowledge(saved: sent, schema: Tune.schema)
    let rows = try store.rows(tune.id.uuidString)
    #expect(rows.current?["_deleted"] == .integer(1) && rows.current?["_systemFields"] != .null)
    #expect(try store.isPending(tune.id.uuidString))
    #expect(try store.context.record(id: tune.id) == nil)
}

@MainActor
@Test func anAcknowledgedDeletionRemovesTheRows() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    try store.database.acknowledge(deleted: recordID(tune.id.uuidString), recordType: Tune.recordType)
    #expect(try store.rows(tune.id.uuidString).current == nil)
}

@MainActor
@Test func aRecordSavedAgainDuringItsDeletionUploadsAsNew() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    try store.save(tune)
    try store.database.acknowledge(deleted: recordID(tune.id.uuidString), recordType: Tune.recordType)
    let rows = try store.rows(tune.id.uuidString)
    #expect(rows.current?["_systemFields"] == .null && rows.current?["_deleted"] == .integer(0))
    #expect(try store.isPending(tune.id.uuidString))
}

// MARK: - Failures

@MainActor
@Test func aConflictMergesTheServerRecordAndSendsAgain() throws {
    let store = try Store()
    var tune = try store.syncedTune(title: "Blue", plays: 0)
    tune.title = "Mine"
    try store.save(tune)
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server(tune.id.uuidString, title: "Blue", plays: 8)])
    #expect(try store.database.resolve(error, for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    let rows = try store.rows(tune.id.uuidString)
    #expect(title(rows.current) == "Mine" && plays(rows.current) == 8)
}

@MainActor
@Test func aConflictWhoseMergeEqualsTheServerIsNotSentAgain() throws {
    let store = try Store()
    var tune = try store.syncedTune(title: "Blue")
    tune.title = "Red"
    try store.save(tune)
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server(tune.id.uuidString, title: "Red", plays: 0)])
    #expect(try !store.database.resolve(error, for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
}

@MainActor
@Test func anUnknownItemUploadsAsNew() throws {
    let store = try Store()
    var tune = try store.syncedTune()
    tune.title = "Mine"
    try store.save(tune)
    for code in [CKError.Code.unknownItem, .zoneNotFound] {
        #expect(try store.database.resolve(CKError(code), for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
        let rows = try store.rows(tune.id.uuidString)
        #expect(rows.current?["_systemFields"] == .null && rows.base == nil && title(rows.current) == "Mine")
    }
}

@MainActor
@Test func aDeletionTheServerCannotFindIsDone() throws {
    let store = try Store()
    let tune = try store.syncedTune()
    try store.delete(tune)
    #expect(try !store.database.resolve(CKError(.unknownItem), for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
    #expect(try store.rows(tune.id.uuidString).current == nil)
}

@MainActor
@Test func retryableErrorsAndFullStorageLeaveTheRowsPending() throws {
    let store = try Store()
    let tune = Tune(title: "Blue", plays: 0)
    try store.save(tune)
    let codes: [CKError.Code] = [.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy, .notAuthenticated, .quotaExceeded, .internalError]
    for code in codes {
        #expect(try !store.database.resolve(CKError(code), for: recordID(tune.id.uuidString), schema: Tune.schema, assets: store.assets))
        #expect(try store.isPending(tune.id.uuidString))
    }
}

// MARK: - Zones and accounts

@MainActor
@Test func aDeletedZoneLosesItsRowsAndOnlyThose() throws {
    let store = try Store()
    let work: Zone = "Work"
    let kept = try store.syncedTune()
    try store.fetch(server(UUID().uuidString, title: "Gone", plays: 0, zone: work))
    try store.database.removeRecords(in: work)
    #expect(try store.database.rows("SELECT * FROM \"Tune\" WHERE \"_zoneName\" = 'Work'").isEmpty)
    #expect(try store.rows(kept.id.uuidString).current != nil)
}

@MainActor
@Test func anEncryptionResetMakesEveryRecordUploadAgain() throws {
    let store = try Store()
    var edited = try store.syncedTune()
    edited.title = "Mine"
    try store.save(edited)
    let deleted = try store.syncedTune()
    try store.delete(deleted)
    try store.database.clearSystemFields(in: .records)
    let rows = try store.rows(edited.id.uuidString)
    #expect(title(rows.current) == "Mine" && rows.current?["_systemFields"] == .null && rows.base == nil)
    #expect(try store.isPending(edited.id.uuidString))
    #expect(try store.rows(deleted.id.uuidString).current == nil)
}

@MainActor
@Test func signingOutRemovesEveryRecord() throws {
    let store = try Store()
    _ = try store.syncedTune()
    try store.save(Tune(title: "Unsent", plays: 0))
    try store.database.removeAllRecords()
    #expect(try store.database.rows("SELECT * FROM \"Tune\"").isEmpty)
    #expect(try store.database.rows("SELECT * FROM \"RecordLink\"").isEmpty)
}

// MARK: - Asset files

/// A link for `Tune.cover` on the tune named `source`, holding the asset `assetID`.
private func serverAssetLink(source: String, assetID: UUID, file: URL?) -> CKRecord {
    let name = RecordLink.id(source: "Tune.cover", kind: .manyToOne, sourceName: source, targetName: "").uuidString
    let record = CKRecord(recordType: RecordLink.recordType, recordID: recordID(name))
    record["source"] = "Tune.cover"
    record["sourceName"] = source
    record["assetID"] = assetID.uuidString
    record[RecordLink.assetKey] = file.map(CKAsset.init(fileURL:))
    return record
}

private func temporaryFile(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).tmp")
    try Data(text.utf8).write(to: url)
    return url
}

@MainActor
@Test func aFetchedAssetIsCopiedOutOfCloudKitsFile() throws {
    let store = try Store()
    let id = UUID()
    let downloaded = try temporaryFile("cover")
    try store.database.apply(serverAssetLink(source: "A", assetID: id, file: downloaded), schema: RecordLink.schema, assets: store.assets)
    try FileManager.default.removeItem(at: downloaded)
    let copy = store.assets.appending(path: "\(id.uuidString).asset")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "cover")
}

@MainActor
@Test func aFetchedAssetKeepsAFileAlreadyThere() throws {
    let store = try Store()
    let id = UUID()
    try FileManager.default.createDirectory(at: store.assets, withIntermediateDirectories: true)
    let existing = store.assets.appending(path: "\(id.uuidString).asset")
    try Data("mine".utf8).write(to: existing)
    try store.database.apply(serverAssetLink(source: "A", assetID: id, file: try temporaryFile("theirs")), schema: RecordLink.schema, assets: store.assets)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "mine")
}

@MainActor
@Test func bothDevicesReplacingAnAssetKeepOursWithItsOwnFile() throws {
    let store = try Store()
    let (first, mine, theirs) = (UUID(), UUID(), UUID())
    let link = serverAssetLink(source: "A", assetID: first, file: try temporaryFile("first"))
    try store.database.apply(link, schema: RecordLink.schema, assets: store.assets)
    // This device replaces the cover and saves: the link's base row keeps the first ID.
    let key = RecordKey(recordType: RecordLink.recordType, name: link.recordID.recordName, zone: .records)
    try store.database.writeRecord(RecordLink.schema, key: key, values: ["assetID": .text(mine.uuidString)], edited: nil, now: 0)
    try store.database.apply(serverAssetLink(source: "A", assetID: theirs, file: try temporaryFile("theirs")), schema: RecordLink.schema, assets: store.assets)

    let rows = try store.rows(link.recordID.recordName, type: RecordLink.recordType)
    #expect(rows.current?["assetID"] == .text(mine.uuidString))
    #expect(rows.base?["assetID"] == .text(theirs.uuidString))
    // Every copy's file is on hand for a future merge of the data itself.
    #expect(FileManager.default.fileExists(atPath: store.assets.appending(path: "\(theirs.uuidString).asset").path))
    #expect(FileManager.default.fileExists(atPath: store.assets.appending(path: "\(first.uuidString).asset").path))
}

@MainActor
@Test func aReplacedAssetWinsOverOneClearedHere() throws {
    let store = try Store()
    let link = serverAssetLink(source: "A", assetID: UUID(), file: try temporaryFile("first"))
    try store.database.apply(link, schema: RecordLink.schema, assets: store.assets)
    let key = RecordKey(recordType: RecordLink.recordType, name: link.recordID.recordName, zone: .records)
    try store.database.remove(key, now: 0)
    let replacement = UUID()
    try store.database.apply(serverAssetLink(source: "A", assetID: replacement, file: try temporaryFile("new")), schema: RecordLink.schema, assets: store.assets)
    let rows = try store.rows(link.recordID.recordName, type: RecordLink.recordType)
    #expect(rows.current?["_deleted"] == .integer(0) && rows.current?["assetID"] == .text(replacement.uuidString))
}

@MainActor
@Test func aLinkIsSentWithItsAssetFile() throws {
    let store = try Store()
    let id = UUID()
    try FileManager.default.createDirectory(at: store.assets, withIntermediateDirectories: true)
    try Data("cover".utf8).write(to: store.assets.appending(path: "\(id.uuidString).asset"))
    let key = RecordKey(recordType: RecordLink.recordType, name: UUID().uuidString, zone: .records)
    try store.database.writeRecord(
        RecordLink.schema, key: key,
        values: ["source": .text("Tune.cover"), "sourceName": .text("A"), "assetID": .text(id.uuidString)], edited: nil, now: 0
    )
    let record = try #require(try store.database.recordToSend(for: recordID(key.name), schema: RecordLink.schema, assets: store.assets))
    #expect((record[RecordLink.assetKey] as? CKAsset)?.fileURL?.lastPathComponent == "\(id.uuidString).asset")
}

@MainActor
@Test func aLinkWhoseAssetFileIsMissingIsNotSent() throws {
    let store = try Store()
    let key = RecordKey(recordType: RecordLink.recordType, name: UUID().uuidString, zone: .records)
    try store.database.writeRecord(
        RecordLink.schema, key: key,
        values: ["source": .text("Tune.cover"), "sourceName": .text("A"), "assetID": .text(UUID().uuidString)], edited: nil, now: 0
    )
    #expect(try store.database.recordToSend(for: recordID(key.name), schema: RecordLink.schema, assets: store.assets) == nil)
}

@MainActor
@Test func unusedAssetFilesAreRemovedAndNamedOnesKept() throws {
    let store = try Store()
    let (first, mine, unused) = (UUID(), UUID(), UUID())
    let link = serverAssetLink(source: "A", assetID: first, file: try temporaryFile("first"))
    try store.database.apply(link, schema: RecordLink.schema, assets: store.assets)
    let key = RecordKey(recordType: RecordLink.recordType, name: link.recordID.recordName, zone: .records)
    try store.database.writeRecord(RecordLink.schema, key: key, values: ["assetID": .text(mine.uuidString)], edited: nil, now: 0)
    for id in [mine, unused] {
        try Data("x".utf8).write(to: store.assets.appending(path: "\(id.uuidString).asset"))
    }
    let other = store.assets.appending(path: "notes.txt")
    try Data("x".utf8).write(to: other)

    try store.database.removeUnusedAssetFiles(in: store.assets)
    func exists(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: store.assets.appending(path: "\(id.uuidString).asset").path) }
    #expect(exists(first), "the base row names it")
    #expect(exists(mine), "the current row names it")
    #expect(!exists(unused))
    #expect(FileManager.default.fileExists(atPath: other.path))
}
