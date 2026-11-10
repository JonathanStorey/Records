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

private let memory = RecordContainer.Configuration(storage: .inMemory, cloudKit: .none)

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "RecordsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "test.sqlite")
}

// MARK: - Registering types

@Test func relatedTypesAreRegistered() throws {
    let container = try RecordContainer(for: Page.self, configuration: memory)
    #expect(container.recordTypes == ["Label", "Page", "RecordLink"])
}

@Test func bothSidesOfAnInverseAreRegistered() throws {
    let container = try RecordContainer(for: Profile.self, configuration: memory)
    #expect(container.recordTypes == ["Profile", "RecordLink", "User"])
}

@Test func namingATypeTwiceIsFine() throws {
    let container = try RecordContainer(for: [Label.self, Page.self, Label.self], configuration: memory)
    #expect(container.recordTypes == ["Label", "Page", "RecordLink"])
}

// MARK: - Checking types

@Test func twoTypesCantShareARecordType() {
    #expect(throws: RecordContainerError.duplicateRecordType("Gadget")) {
        try RecordContainer(for: GadgetV1.self, GadgetV2.self, configuration: memory)
    }
}

@Test func recordLinkIsReserved() {
    #expect(throws: RecordContainerError.reservedRecordType("RecordLink")) {
        try RecordContainer(for: FakeLink.self, configuration: memory)
    }
}

@Test func fieldsCantStartWithAnUnderscore() {
    #expect(throws: RecordContainerError.reservedFieldName(recordType: "Underscored", field: "_hidden")) {
        try RecordContainer(for: Underscored.self, configuration: memory)
    }
}

@Test func anInverseMustPointBack() {
    #expect(throws: RecordContainerError.invalidInverse(recordType: "Imposter", property: "accountID")) {
        try RecordContainer(for: Imposter.self, configuration: memory)
    }
}

// MARK: - Tables

@Test func eachTypeGetsATable() throws {
    let container = try RecordContainer(for: Page.self, configuration: memory)
    #expect(try container.database.tableNames() == ["Label", "Page", "RecordLink", "_SyncState"])
}

@Test func aTableHasBookkeepingThenFields() throws {
    let container = try RecordContainer(for: Book.self, configuration: memory)
    let bookkeeping = Database.bookkeeping.map(\.name)
    #expect(try container.database.columnNames("Book") == bookkeeping + ["title"])
    #expect(try container.database.columnNames("RecordLink") == bookkeeping + ["source", "sourceName", "targetName", "order", "assetID"])
}

@Test func renamedFieldsUseTheirStoredName() throws {
    let container = try RecordContainer(for: Novel.self, configuration: memory)
    let columns = try container.database.columnNames("Novel")
    #expect(columns.contains("released") && !columns.contains("year"))
    #expect(!columns.contains("cover")) // assets live on links
    #expect(!columns.contains("createdAt")) // timestamps aren't fields
}

@Test func tablesGetTheirIndexes() throws {
    let container = try RecordContainer(for: Page.self, configuration: memory)
    #expect(try container.database.indexNames("Page") == ["Page_pending"])
    #expect(try container.database.indexNames("RecordLink") == ["RecordLink_pending", "RecordLink_source", "RecordLink_target"])
}

@Test func schemaDescribesFieldsAssetsAndReferences() {
    let schema = Novel.schema
    #expect(schema.recordType == "Novel")
    #expect(schema.fields.map(\.key) == ["title", "subtitle", "tags", "released", "note", "shop"])
    #expect(schema.fields.first { $0.key == "released" }?.name == "year")
    #expect(schema.fields.filter(\.isOptional).map(\.key) == ["subtitle", "note", "shop"])
    #expect(schema.fields.filter(\.isEncrypted).map(\.key) == ["note", "shop"])
    #expect(schema.assets == ["cover"])
    #expect(schema.references.map(\.property) == ["sequel", "writers", "editorID"])
    #expect(schema.references.map(\.isToMany) == [false, true, false])
    #expect(schema.references.map(\.holdsIDs) == [false, false, true])

    let from = Writer.schema.references[0]
    #expect(from.isFrom && from.inverseOf == "writers" && from.target.recordType == "Novel")
    #expect(Profile.schema.references[0].deleteSelf)
    #expect(Crate.schema.references.allSatisfy(\.isSorted))
}

// MARK: - Files

@Test func reopeningAFileKeepsItsTables() throws {
    let url = temporaryFile()
    _ = try RecordContainer(for: Page.self, configuration: .init(storage: .file(url), cloudKit: .none))
    let reopened = try RecordContainer(for: Page.self, configuration: .init(storage: .file(url), cloudKit: .none))
    #expect(try reopened.database.tableNames() == ["Label", "Page", "RecordLink", "_SyncState"])
}

@Test func changedFieldsAddAndDropColumns() throws {
    let url = temporaryFile()
    let configuration = RecordContainer.Configuration(storage: .file(url), cloudKit: .none)
    _ = try RecordContainer(for: GadgetV1.self, configuration: configuration)
    let updated = try RecordContainer(for: GadgetV2.self, configuration: configuration)
    #expect(try updated.database.columnNames("Gadget") == Database.bookkeeping.map(\.name) + ["name", "size"])
}
