import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import Records

@MainActor
private func makeContext(for types: any Record.Type...) throws -> RecordContext {
    try RecordContainer(for: types, url: nil).mainContext
}

/// The current row of `id` in `table`.
@MainActor
private func currentRow(_ table: String, _ id: UUID, in context: RecordContext) throws -> [String: SQLValue] {
    let rows = try context.database.rows(
        "SELECT * FROM \"\(table)\" WHERE \"_name\" = ? AND \"_isCurrent\" = 1", [.text(id.uuidString)]
    )
    return try #require(rows.first)
}

@MainActor
private func linkRows(of id: UUID, in context: RecordContext) throws -> [[String: SQLValue]] {
    try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"sourceName\" = ? ORDER BY \"order\"", [.text(id.uuidString)]
    )
}

// MARK: - The record's row

@MainActor
@Test func insertWritesTheFields() throws {
    let context = try makeContext(for: Venue.self)
    let venue = Venue(
        id: UUID(), name: "Hall", mood: .calm, rating: .two,
        address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm]
    )
    try context.insert(venue)

    let row = try currentRow("Venue", venue.id, in: context)
    #expect(row["title"] == .text("Hall")) // its @Renamed name
    #expect(row["mood"] == .text("calm"))
    #expect(row["rating"] == .integer(2))
    #expect(row["previous"] == .null)
    guard case .blob(let address) = row["address"] else { Issue.record("address isn't a blob"); return }
    #expect(try JSONDecoder().decode(Address.self, from: address) == venue.address)
}

@MainActor
@Test func insertedRecordsWaitToUpload() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(id: UUID(), title: "Notes", labels: [], pinnedIDs: [])
    try context.insert(page)

    let row = try currentRow("Page", page.id, in: context)
    #expect(row["_systemFields"] == .null)
    #expect(row["_deleted"] == .integer(0))
    #expect(row["_createdAt"] == row["_modifiedAt"])
    let pending = try context.database.rows(
        "SELECT \"_name\" FROM \"Page\" WHERE \"_isCurrent\" = 0 OR \"_systemFields\" IS NULL OR \"_deleted\" = 1"
    )
    #expect(pending.map { $0["_name"] } == [Optional(SQLValue.text(page.id.uuidString))])
}

@MainActor
@Test func insertUsesTheContextsZone() throws {
    let context = try makeContext(for: Page.self)
    let first = Page(id: UUID(), title: "One", labels: [], pinnedIDs: [])
    try context.insert(first)
    context.zone = "Work"
    let second = Page(id: UUID(), title: "Two", labels: [], pinnedIDs: [])
    try context.insert(second)

    #expect(try currentRow("Page", first.id, in: context)["_zoneName"] == .text("Records"))
    #expect(try currentRow("Page", second.id, in: context)["_zoneName"] == .text("Work"))
    #expect(try currentRow("Page", second.id, in: context)["_zoneOwner"] == .text(CKCurrentUserDefaultName))
}

@MainActor
@Test func encryptedAndArchivedFieldsAreStored() throws {
    let context = try makeContext(for: Novel.self)
    let novel = Novel(
        id: UUID(), title: "Notes", subtitle: nil, tags: ["a", "b"], year: 1843, note: "secret",
        cover: nil, shop: Coordinate(latitude: 51.5, longitude: -0.12), sequel: nil, writers: [], editorID: nil
    )
    try context.insert(novel)

    let row = try currentRow("Novel", novel.id, in: context)
    #expect(row["note"] == .text("secret"))
    #expect(row["released"] == .integer(1843))
    let tags = try #require(row["tags"])
    #expect(FieldKind.archived.recordValue(tags) as? [String] == ["a", "b"])
    let shop = try #require(row["shop"])
    let location = try #require(FieldKind.archived.recordValue(shop) as? CLLocation)
    #expect(Coordinate(location).latitude == 51.5)
}

// MARK: - Links

@MainActor
@Test func insertWritesOrderedLinks() throws {
    let context = try makeContext(for: Page.self)
    let items = ["a", "b", "c"].map { Label(id: UUID(), name: $0) }
    let page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    try context.insert(page)

    let links = try linkRows(of: page.id, in: context)
    #expect(links.map { $0["targetName"] } == items.map { Optional(SQLValue.text($0.id.uuidString)) })
    #expect(links.allSatisfy { $0["source"] == .text("Page.labels") })
    #expect(links.allSatisfy { $0["order"] != .null })
    #expect(links.allSatisfy { $0["_zoneName"] == .text("Records") })
}

@MainActor
@Test func insertWritesAnAssetLink() throws {
    let context = try makeContext(for: Novel.self)
    let novel = Novel(
        id: UUID(), title: "Notes", subtitle: nil, tags: [], year: 1843, note: nil,
        cover: Data("cover".utf8), shop: nil, sequel: nil, writers: [], editorID: nil
    )
    try context.insert(novel)

    let links = try linkRows(of: novel.id, in: context)
    #expect(links.count == 1)
    #expect(links.first?["source"] == .text("Novel.cover"))
    #expect(links.first?["assetID"] == novel._cover.id.map { SQLValue.text($0.uuidString) })
}

@MainActor
@Test func insertDoesNotSaveTheTargets() throws {
    let context = try makeContext(for: Page.self)
    let label = Label(id: UUID(), name: "a")
    try context.insert(Page(id: UUID(), title: "Notes", labels: [label], pinnedIDs: []))
    #expect(try context.database.rows("SELECT * FROM \"Label\"").isEmpty)
}

// MARK: - Errors

@MainActor
@Test func insertingAnIDTwiceIsAnError() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(id: UUID(), title: "Notes", labels: [Label(id: UUID(), name: "a")], pinnedIDs: [])
    try context.insert(page)
    #expect(throws: RecordContextError.duplicateID(page.id)) {
        try context.insert(page)
    }
    #expect(try linkRows(of: page.id, in: context).count == 1) // the failed insert wrote nothing
}

@MainActor
@Test func insertingAnUnregisteredTypeIsAnError() throws {
    let context = try makeContext(for: Page.self)
    #expect(throws: RecordContextError.unregisteredType("Venue")) {
        try context.insert(Venue(id: UUID(), name: "Hall", mood: .calm, rating: nil, address: Address(street: "", city: ""), previous: nil, moods: []))
    }
}

// MARK: - Values

@Test func valuesRoundTripThroughTheirColumns() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000.5)
    #expect(FieldKind.date.recordValue(FieldKind.date.sqlValue(date)) as? Date == date)
    #expect(FieldKind.integer.recordValue(FieldKind.integer.sqlValue(true)) as? Bool == true)
    #expect(FieldKind.real.recordValue(FieldKind.real.sqlValue(2.5)) as? Double == 2.5)
    #expect(FieldKind.bytes.recordValue(FieldKind.bytes.sqlValue(Data([1, 2]))) as? Data == Data([1, 2]))
    #expect(FieldKind.text.sqlValue(nil) == .null)
    #expect(FieldKind.text.recordValue(.null) == nil)
}

/// The context holds the database, not the container, so a container and its main context
/// don't keep each other alive, and the context still works after the container is gone.
@MainActor @Test func contextOutlivesContainer() throws {
    weak var released: RecordContainer?
    let context: RecordContext
    do {
        let container = try RecordContainer.inMemory(for: Venue.self)
        released = container
        context = container.mainContext
    }
    #expect(released == nil)
    try context.insert(Venue(id: UUID(), name: "Hall", mood: .calm, rating: nil, address: Address(street: "", city: ""), previous: nil, moods: []))
    #expect(try context.database.rows("SELECT * FROM \"Venue\"").count == 1)
}
