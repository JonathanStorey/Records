import CloudKit
import Foundation
import Testing
@testable import Records

@Record("Gadget")
struct GadgetV1 {
    var id: UUID
    var name: String
    var color: String?
}

/// The same record type after `color` was removed and `size` added.
@Record("Gadget")
struct GadgetV2 {
    var id: UUID
    var name: String
    var size: Int?
}

@Record
struct Underscored {
    var id: UUID
    var _hidden: Int
}

@Record("RecordLink")
struct FakeLink {
    var id: UUID
}

/// Names `Account.settingsID`, which points at `Settings`, not here.
@Record
struct Imposter {
    var id: UUID
    @Reference(from: \Account.settingsID) var accountID: UUID?
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "RecordsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "test.sqlite")
}

// MARK: - Registering types

@Test func relatedTypesAreRegistered() throws {
    let container = try RecordContainer.inMemory(for: Page.self)
    #expect(container.recordTypes == ["Label", "Page", "RecordLink"])
}

@Test func bothSidesOfAnInverseAreRegistered() throws {
    let container = try RecordContainer.inMemory(for: Profile.self)
    #expect(container.recordTypes == ["Profile", "RecordLink", "User"])
}

@Test func namingATypeTwiceIsFine() throws {
    let container = try RecordContainer.inMemory(for: Label.self, Page.self, Label.self)
    #expect(container.recordTypes == ["Label", "Page", "RecordLink"])
}

// MARK: - Checking types

@Test func twoTypesCantShareARecordType() {
    #expect(throws: RecordContainerError.duplicateRecordType("Gadget")) {
        try RecordContainer.inMemory(for: GadgetV1.self, GadgetV2.self)
    }
}

@Test func recordLinkIsReserved() {
    #expect(throws: RecordContainerError.reservedRecordType("RecordLink")) {
        try RecordContainer.inMemory(for: FakeLink.self)
    }
}

@Test func fieldsCantStartWithAnUnderscore() {
    #expect(throws: RecordContainerError.reservedFieldName(recordType: "Underscored", field: "_hidden")) {
        try RecordContainer.inMemory(for: Underscored.self)
    }
}

@Test func anInverseMustPointBack() {
    #expect(throws: RecordContainerError.invalidInverse(recordType: "Imposter", property: "accountID")) {
        try RecordContainer.inMemory(for: Imposter.self)
    }
}

// MARK: - Tables

@Test func eachTypeGetsATable() throws {
    let container = try RecordContainer.inMemory(for: Page.self)
    #expect(try container.database.tableNames() == ["Label", "Page", "RecordLink", "_SyncState"])
}

@Test func aTableHasBookkeepingThenFields() throws {
    let container = try RecordContainer.inMemory(for: Book.self)
    let bookkeeping = Database.bookkeeping.map(\.name)
    #expect(try container.database.columnNames("Book") == bookkeeping + ["title"])
    #expect(try container.database.columnNames("RecordLink") == bookkeeping + ["source", "sourceName", "targetName", "order", "assetID"])
}

@Test func renamedFieldsUseTheirStoredName() throws {
    let container = try RecordContainer.inMemory(for: Novel.self)
    let columns = try container.database.columnNames("Novel")
    #expect(columns.contains("released") && !columns.contains("year"))
    #expect(!columns.contains("cover")) // assets live on links
    #expect(!columns.contains("createdAt")) // timestamps aren't fields
}

@Test func tablesGetTheirIndexes() throws {
    let container = try RecordContainer.inMemory(for: Page.self)
    #expect(try container.database.indexNames("Page") == ["Page_pending"])
    #expect(try container.database.indexNames("RecordLink") == ["RecordLink_pending", "RecordLink_source", "RecordLink_target"])
}

@Test func schemaDescribesFieldsAndReferences() {
    let schema = Novel.schema
    #expect(schema.recordType == "Novel")
    #expect(schema.fields.map(\.key) == ["title", "subtitle", "tags", "released", "note", "shop"])
    #expect(schema.fields.first { $0.key == "released" }?.name == "year")
    #expect(schema.fields.filter(\.isOptional).map(\.key) == ["subtitle", "note", "shop"])
    #expect(schema.fields.filter(\.isEncrypted).map(\.key) == ["note", "shop"])
    #expect(schema.references.map(\.property) == ["sequel", "writers", "editorID"])
    #expect(schema.references.map(\.isToMany) == [false, true, false])
    #expect(schema.references.map(\.holdsIDs) == [false, false, true])

    let from = Writer.schema.references[0]
    #expect(from.isFrom && from.inverseOf == "writers" && from.target.recordType == "Novel")
    #expect(Profile.schema.references[0].deleteSelf)
    #expect(Crate.schema.references.allSatisfy { $0.isSorted })
}

// MARK: - Files

@Test func reopeningAFileKeepsItsTables() throws {
    let url = temporaryFile()
    _ = try RecordContainer(for: [Page.self], url: url)
    let reopened = try RecordContainer(for: [Page.self], url: url)
    #expect(try reopened.database.tableNames() == ["Label", "Page", "RecordLink", "_SyncState"])
}

@Test func changedFieldsAddAndDropColumns() throws {
    let url = temporaryFile()
    _ = try RecordContainer(for: [GadgetV1.self], url: url)
    let updated = try RecordContainer(for: [GadgetV2.self], url: url)
    #expect(try updated.database.columnNames("Gadget") == Database.bookkeeping.map(\.name) + ["name", "size"])
}

// MARK: - Zones

@Test func localZonesDontSync() {
    #expect(Zone.records.name == "Records" && Zone.records.isSynced)
    #expect(!Zone.local.isSynced)
    #expect(Zone("Music").isSynced)
    #expect(RecordContainer.defaultURL.lastPathComponent == "default.records")
}

@MainActor
@Test func theMainContextIsTheSameEveryTime() throws {
    let container = try RecordContainer.inMemory(for: Page.self)
    container.mainContext.zone = "Music"
    #expect(container.mainContext === container.mainContext)
    #expect(container.mainContext.zone == "Music")
}

@Test func fieldsKnowHowTheyAreStored() {
    let kinds = Dictionary(uniqueKeysWithValues: Novel.schema.fields.map { ($0.key, $0.kind) })
    #expect(kinds == ["title": .text, "subtitle": .text, "tags": .archived, "released": .integer, "note": .text, "shop": .archived])
    #expect(FieldCoding(Date.self).kind == .date)
    #expect(FieldCoding(Double.self).kind == .real)
    #expect(FieldCoding(Bool.self).kind == .integer)
    #expect(FieldCoding(Data.self).kind == .bytes)
    #expect(FieldCoding(Address.self).kind == .bytes) // Codable, stored as JSON
    #expect(FieldCoding(Mood.self).kind == .text) // its raw value
    #expect(FieldCoding(Rating.self).kind == .integer)
    #expect(FieldCoding([Mood].self).kind == .bytes)
}
