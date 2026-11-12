import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import Records

@MainActor
private func makeContext(for types: any Record.Type...) throws -> RecordContext {
    try RecordContainer(for: types, url: nil).mainContext
}

/// The current row of `id` in `table`, in `zone` when one is given.
@MainActor
private func currentRow<R>(_ table: String, _ id: RecordID<R>, in context: RecordContext, zone: Zone? = nil) throws -> [String: SQLValue] {
    var sql = "SELECT * FROM \"\(table)\" WHERE \"_name\" = ? AND \"_isCurrent\" = 1"
    var values: [SQLValue] = [.text(id.uuidString)]
    if let zone {
        sql += " AND \"_zoneName\" = ? AND \"_zoneOwner\" = ?"
        values += [.text(zone.name), .text(zone.ownerName)]
    }
    let rows = try context.database.rows(sql, values)
    return try #require(rows.first)
}

@MainActor
private func linkRows<R>(of id: RecordID<R>, in context: RecordContext) throws -> [[String: SQLValue]] {
    try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"sourceName\" = ? ORDER BY \"order\"", [.text(id.uuidString)]
    )
}

// MARK: - The record's row

@MainActor
@Test func saveWritesTheFields() throws {
    let context = try makeContext(for: Venue.self)
    let venue = Venue(
        name: "Hall", mood: .calm, rating: .two,
        address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm]
    )
    context.insert(venue)
    try context.save()

    let row = try currentRow("Venue", venue.id, in: context)
    #expect(row["title"] == .text("Hall")) // its @Renamed name
    #expect(row["mood"] == .text("calm"))
    #expect(row["rating"] == .integer(2))
    #expect(row["previous"] == .null)
    guard case .blob(let address) = row["address"] else { Issue.record("address isn't a blob"); return }
    #expect(try JSONDecoder().decode(Address.self, from: address) == venue.address)
}

@MainActor
@Test func savedRecordsWaitToUpload() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [])
    context.insert(page)
    try context.save()

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
@Test func saveUsesTheContextsZone() throws {
    let context = try makeContext(for: Page.self)
    let first = Page(title: "One", labels: [])
    context.insert(first)
    try context.save()
    context.zone = "Work"
    let second = Page(title: "Two", labels: [])
    context.insert(second)
    try context.save()

    #expect(try currentRow("Page", first.id, in: context)["_zoneName"] == .text("Records"))
    #expect(try currentRow("Page", second.id, in: context)["_zoneName"] == .text("Work"))
    #expect(try currentRow("Page", second.id, in: context)["_zoneOwner"] == .text(CKCurrentUserDefaultName))
}

/// One main context writes to several zones by switching `zone` between saves. Each record
/// and its links land in the zone that was set when it was saved.
@MainActor
@Test func mainContextSwitchesBetweenZones() throws {
    let container = try RecordContainer(for: [Page.self], url: nil)
    let shared = Zone(CKRecordZone.ID(zoneName: "Team", ownerName: "_friend"))
    let zones: [Zone] = [.records, "Work", .local, shared]
    var pages: [Page] = []
    for zone in zones {
        container.mainContext.zone = zone
        let page = Page(title: zone.name, labels: [Label(name: "tag")])
        container.mainContext.insert(page)
        try container.mainContext.save()
        pages.append(page)
    }

    // The zone stays set because mainContext is the same context every time.
    #expect(container.mainContext.zone == shared)
    let context = container.mainContext
    for (page, zone) in zip(pages, zones) {
        let row = try currentRow("Page", page.id, in: context)
        #expect(row["_zoneName"] == .text(zone.name))
        #expect(row["_zoneOwner"] == .text(zone.ownerName))
        let links = try linkRows(of: page.id, in: context)
        #expect(links.count == 1)
        #expect(links.allSatisfy { $0["_zoneName"] == .text(zone.name) && $0["_zoneOwner"] == .text(zone.ownerName) })
    }
    #expect(try context.database.rows("SELECT * FROM \"Page\"").count == zones.count)
}

/// A row is named by its zone and ID together, as a CloudKit record ID is, so the same record
/// can be in two zones, and saving it in one leaves the other alone.
@MainActor
@Test func sameIDCanBeSavedToTwoZones() throws {
    let context = try makeContext(for: Page.self)
    var page = Page(title: "One", labels: [Label(name: "tag")])
    context.insert(page)
    try context.save()
    context.zone = "Work"
    page.title = "Two"
    context.insert(page)
    try context.save()

    #expect(try currentRow("Page", page.id, in: context, zone: .records)["title"] == .text("One"))
    #expect(try currentRow("Page", page.id, in: context, zone: "Work")["title"] == .text("Two"))
    let zones = try context.database.rows("SELECT \"_zoneName\" FROM \"Page\" ORDER BY \"_zoneName\"")
    #expect(zones.map { $0["_zoneName"] } == [Optional(SQLValue.text("Records")), Optional(SQLValue.text("Work"))])
    // Each zone has its own link; the link's ID comes from the record and reference, so it repeats too.
    #expect(try linkRows(of: page.id, in: context).count == 2)
}

@MainActor
@Test func encryptedAndArchivedFieldsAreStored() throws {
    let context = try makeContext(for: Novel.self)
    let novel = Novel(
        title: "Notes", subtitle: nil, tags: ["a", "b"], year: 1843, note: "secret",
        cover: nil, shop: Coordinate(latitude: 51.5, longitude: -0.12), sequel: nil, writers: [], editor: nil
    )
    context.insert(novel)
    try context.save()

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
@Test func saveWritesOrderedLinks() throws {
    let context = try makeContext(for: Page.self)
    let items = ["a", "b", "c"].map { Label(name: $0) }
    let page = Page(title: "Notes", labels: items)
    context.insert(page)
    try context.save()

    let links = try linkRows(of: page.id, in: context)
    #expect(links.map { $0["targetName"] } == items.map { Optional(SQLValue.text($0.id.uuidString)) })
    #expect(links.allSatisfy { $0["source"] == .text("Page.labels") })
    #expect(links.allSatisfy { $0["order"] != .null })
    #expect(links.allSatisfy { $0["_zoneName"] == .text("Records") })
}

@MainActor
@Test func saveWritesAnAssetLink() throws {
    let context = try makeContext(for: Novel.self)
    let novel = Novel(
        title: "Notes", subtitle: nil, tags: [], year: 1843, note: nil,
        cover: Data("cover".utf8), shop: nil, sequel: nil, writers: [], editor: nil
    )
    context.insert(novel)
    try context.save()

    let links = try linkRows(of: novel.id, in: context)
    #expect(links.count == 1)
    #expect(links.first?["source"] == .text("Novel.cover"))
    #expect(links.first?["assetID"] == novel._cover.id.map { SQLValue.text($0.uuidString) })
}

// MARK: - Errors

@MainActor
@Test func savingAgainUpdatesTheRecord() throws {
    let context = try makeContext(for: Page.self)
    let a = Label(name: "a"), b = Label(name: "b")
    var page = Page(title: "Draft", labels: [a, b])
    context.insert(page)
    try context.save()
    let created = try currentRow("Page", page.id, in: context)["_createdAt"]

    page.title = "Final"
    page._labels.values = [b]
    context.insert(page)
    try context.save()

    let rows = try context.database.rows("SELECT * FROM \"Page\"")
    #expect(rows.count == 1)
    let row = try currentRow("Page", page.id, in: context)
    #expect(row["title"] == .text("Final"))
    #expect(row["_createdAt"] == created)
    // The link to the dropped label never synced, so it's gone.
    let links = try linkRows(of: page.id, in: context)
    #expect(links.map { $0["targetName"] } == [Optional(SQLValue.text(b.id.uuidString))])
}

/// Once a record has synced, saving keeps its synced values in a base row until the next
/// upload, and a dropped link is marked deleted so the deletion reaches the server. A link
/// that didn't change is left alone, so it has nothing to upload.
@MainActor
@Test func savingASyncedRecordKeepsItsBase() throws {
    let context = try makeContext(for: Page.self)
    let a = Label(name: "a"), b = Label(name: "b")
    var page = Page(title: "Synced", labels: [a, b])
    context.insert(page)
    try context.save()
    // Stand in for a sync, which stores each row's system fields.
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00'", [])
    try context.database.run("UPDATE \"RecordLink\" SET \"_systemFields\" = x'00'", [])

    page.title = "Edited"
    page._labels.values = [b]
    context.insert(page)
    try context.save()
    page.title = "Edited again"
    context.insert(page)
    try context.save()

    let base = try context.database.rows(
        "SELECT * FROM \"Page\" WHERE \"_name\" = ? AND \"_isCurrent\" = 0", [.text(page.id.uuidString)]
    )
    #expect(base.map { $0["title"] } == [Optional(SQLValue.text("Synced"))])
    #expect(try currentRow("Page", page.id, in: context)["title"] == .text("Edited again"))

    let current = try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"sourceName\" = ? AND \"_isCurrent\" = 1 ORDER BY \"targetName\"",
        [.text(page.id.uuidString)]
    )
    let deleted = current.filter { $0["_deleted"] == .integer(1) }.map { $0["targetName"] }
    let kept = current.filter { $0["_deleted"] == .integer(0) }.map { $0["targetName"] }
    #expect(deleted == [Optional(SQLValue.text(a.id.uuidString))])
    #expect(kept == [Optional(SQLValue.text(b.id.uuidString))])
    let linkBases = try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"sourceName\" = ? AND \"_isCurrent\" = 0", [.text(page.id.uuidString)]
    )
    #expect(linkBases.isEmpty)
}

/// Saving a dropped target again brings its link back.
@MainActor
@Test func savingRestoresARemovedLink() throws {
    let context = try makeContext(for: Page.self)
    let a = Label(name: "a")
    var page = Page(title: "Notes", labels: [a])
    context.insert(page)
    try context.save()
    try context.database.run("UPDATE \"RecordLink\" SET \"_systemFields\" = x'00'", [])
    page._labels.values = []
    context.insert(page)
    try context.save()
    page._labels.values = [a]
    context.insert(page)
    try context.save()

    let current = try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"sourceName\" = ? AND \"_isCurrent\" = 1", [.text(page.id.uuidString)]
    )
    #expect(current.map { $0["_deleted"] } == [Optional(SQLValue.integer(0))])
}


// MARK: - Values

@Test func valuesRoundTripThroughTheirColumns() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000.5)
    #expect(FieldKind.date.recordValue(FieldKind.date.sqlValue(date)) as? Date == date)
    // Any date reads back exactly, to the last bit.
    let now = Date.now
    #expect(FieldKind.date.recordValue(FieldKind.date.sqlValue(now)) as? Date == now)
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
    context.insert(Venue(name: "Hall", mood: .calm, rating: nil, address: Address(street: "", city: ""), previous: nil, moods: []))
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Venue\"").count == 1)
}


// MARK: - Staging

private func makeVenue() -> Venue {
    Venue(name: "Hall", mood: .calm, rating: nil, address: Address(street: "", city: ""), previous: nil, moods: [])
}

@MainActor
@Test func insertStagesUntilSave() throws {
    let context = try makeContext(for: Venue.self)
    let venue = makeVenue()
    #expect(!context.hasChanges)
    context.insert(venue)
    #expect(context.hasChanges)
    #expect(try context.database.rows("SELECT * FROM \"Venue\"").isEmpty)

    try context.save()
    #expect(!context.hasChanges)
    #expect(try context.database.rows("SELECT * FROM \"Venue\"").count == 1)
}

@MainActor
@Test func rollbackDiscardsStagedChanges() throws {
    let context = try makeContext(for: Venue.self)
    var venue = makeVenue()
    context.insert(venue)
    try context.save()
    venue.name = "Arena"
    context.insert(venue)
    context.insert(makeVenue())
    context.rollback()

    #expect(!context.hasChanges)
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Venue\"").count == 1)
    #expect(try currentRow("Venue", venue.id, in: context)["title"] == .text("Hall"))
}

/// Saving a record that matches its saved copy writes nothing, so a synced record stays in sync.
@MainActor
@Test func savingAnUnchangedRecordWritesNothing() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [Label(name: "a")])
    context.insert(page)
    try context.save()
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00', \"_modifiedAt\" = 0", [])
    try context.database.run("UPDATE \"RecordLink\" SET \"_systemFields\" = x'00', \"_modifiedAt\" = 0", [])
    context.insert(page)
    try context.save()

    #expect(try context.database.rows("SELECT * FROM \"Page\"").map { $0["_modifiedAt"] } == [Optional(SQLValue.real(0))])
    #expect(try linkRows(of: page.id, in: context).map { $0["_modifiedAt"] } == [Optional(SQLValue.real(0))])
}

/// Saving an edited copy writes only the fields that changed, and the rest keep their values.
@MainActor
@Test func savingWritesOnlyChangedFields() throws {
    let context = try makeContext(for: Venue.self)
    var venue = makeVenue()
    context.insert(venue)
    try context.save()
    // Stand in for a column this copy doesn't hold a new value for.
    try context.database.run("UPDATE \"Venue\" SET \"mood\" = 'energetic'", [])

    venue.name = "Arena"
    venue.mood = .calm
    context.insert(venue)
    try context.save()

    let row = try currentRow("Venue", venue.id, in: context)
    #expect(row["title"] == .text("Arena"))
    #expect(row["mood"] == .text("calm"))
}

/// Saving several records is one transaction.
@MainActor
@Test func saveWritesEveryStagedRecord() throws {
    let context = try makeContext(for: Page.self)
    let label = Label(name: "a")
    let page = Page(title: "Notes", labels: [label])
    context.insert(page)
    context.insert(label)
    try context.save()
    #expect(try currentRow("Page", page.id, in: context)["title"] == .text("Notes"))
    #expect(try currentRow("Label", label.id, in: context)["name"] == .text("a"))
}

/// An edit that is undone before the next upload leaves nothing to upload.
@MainActor
@Test func undoingAnEditDropsTheBase() throws {
    let context = try makeContext(for: Venue.self)
    var venue = makeVenue()
    context.insert(venue)
    try context.save()
    try context.database.run("UPDATE \"Venue\" SET \"_systemFields\" = x'00'", [])

    venue.name = "Arena"
    context.insert(venue)
    try context.save()
    venue.name = "Hall"
    context.insert(venue)
    try context.save()

    let pending = try context.database.rows(
        "SELECT * FROM \"Venue\" WHERE \"_isCurrent\" = 0 OR \"_systemFields\" IS NULL OR \"_deleted\" = 1"
    )
    #expect(pending.isEmpty)
}

@MainActor
@Test func deletingAnUnsyncedRecordRemovesIt() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [Label(name: "a")])
    context.insert(page)
    try context.save()
    context.delete(page)
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Page\"").isEmpty)
    #expect(try linkRows(of: page.id, in: context).isEmpty)
}

@MainActor
@Test func deletingASyncedRecordMarksIt() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [Label(name: "a")])
    context.insert(page)
    try context.save()
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00'", [])
    try context.database.run("UPDATE \"RecordLink\" SET \"_systemFields\" = x'00'", [])
    context.delete(page)
    try context.save()

    #expect(try currentRow("Page", page.id, in: context)["_deleted"] == .integer(1))
    #expect(try linkRows(of: page.id, in: context).map { $0["_deleted"] } == [Optional(SQLValue.integer(1))])
}

/// Inserting a deleted record brings it back.
@MainActor
@Test func insertingADeletedRecordRestoresIt() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [])
    context.insert(page)
    try context.save()
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00'", [])
    context.delete(page)
    try context.save()
    context.insert(page)
    try context.save()

    #expect(try currentRow("Page", page.id, in: context)["_deleted"] == .integer(0))
}

/// Deleting a record that was never saved replaces its staged insert, so nothing is written.
@MainActor
@Test func deletingAStagedRecordWritesNothing() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [Label(name: "a")])
    context.insert(page)
    context.delete(page)
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Page\"").isEmpty)
    #expect(try linkRows(of: page.id, in: context).isEmpty)
}

/// Reordering a to-many reference keeps the keys of targets that stay in order, so only the
/// moved target's link changes.
@MainActor
@Test func reorderingRewritesOnlyMovedLinks() throws {
    let context = try makeContext(for: Page.self)
    let labels = ["a", "b", "c"].map { Label(name: $0) }
    var page = Page(title: "Notes", labels: labels)
    context.insert(page)
    try context.save()
    let before = try linkRows(of: page.id, in: context)
    func order(of label: Label) -> SQLValue? {
        before.first { $0["targetName"] == .text(label.id.uuidString) }?["order"]
    }

    page._labels.values = [labels[1], labels[2], labels[0]]
    context.insert(page)
    try context.save()
    let after = try linkRows(of: page.id, in: context)
    #expect(after.map { $0["targetName"] } == page.labels.map { Optional(SQLValue.text($0.id.uuidString)) })
    #expect(after[0]["order"] == order(of: labels[1]))
    #expect(after[1]["order"] == order(of: labels[2]))
    #expect(after[2]["order"] != order(of: labels[0]))
}

// MARK: - Changes

/// The titles of the inserted pages, sorted, for comparing changes.
@MainActor
private func insertedTitles(_ context: RecordContext) -> [String] {
    context.differences.values.compactMap { difference in
        guard case .insert = difference.change, let page = difference.edit as? Page else { return nil }
        return page.title
    }.sorted()
}

/// Inserting a record again replaces its edit, so a record appears once.
@MainActor
@Test func insertingAgainReplacesTheChange() throws {
    let context = try makeContext(for: Page.self)
    var first = Page(title: "Draft", labels: [])
    let second = Page(title: "Other", labels: [])
    context.insert(first)
    context.insert(second)
    first.title = "Final"
    context.insert(first)

    #expect(context.changes == [.insert(first.uuid), .insert(second.uuid)])
    #expect(insertedTitles(context) == ["Final", "Other"])
}

/// `changes` shows the current zone's changes, and `save()` writes every zone's.
@MainActor
@Test func changesBelongToTheirZone() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [])
    context.insert(page)
    context.zone = "Work"
    context.insert(page)
    let work = Page(title: "Plan", labels: [])
    context.insert(work)

    #expect(context.changes == [.insert(page.uuid), .insert(work.uuid)])
    context.zone = .records
    #expect(context.changes == [.insert(page.uuid)])

    try context.save()
    #expect(!context.hasChanges)
    #expect(context.changes.isEmpty)
    #expect(try context.database.rows("SELECT * FROM \"Page\"").count == 3)
}

@MainActor
@Test func deleteAppearsInChanges() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [])
    context.insert(page)
    context.delete(page)
    // Never saved, so nothing is left to write.
    #expect(!context.hasChanges)

    context.insert(page)
    try context.save()
    context.delete(page)
    #expect(context.changes == [.delete(page.uuid)])
    #expect(context.differences.count == 1)
}

// MARK: - Looking up a record

/// The IDs a fetched record's reference holds.
private func referenceIDs(_ record: some Record, _ property: String) -> [UUID] {
    record.referenceStates.first { $0.property == property }?.ids ?? []
}

@MainActor
@Test func recordReadsBackTheSavedValue() throws {
    let context = try makeContext(for: Venue.self)
    var venue = makeVenue()
    venue.rating = .three
    venue.moods = [.calm, .energetic]
    venue.previous = Address(street: "1 Main", city: "Springfield")
    context.insert(venue)
    try context.save()

    #expect(try context.record(id: venue.id, for: Venue.self) == venue)
}

@MainActor
@Test func recordReadsEncryptedAndArchivedFields() throws {
    let context = try makeContext(for: Novel.self)
    let novel = Novel(
        title: "Dune", subtitle: nil, tags: ["sf", "classic"], year: 1965, note: "secret",
        cover: nil, shop: Coordinate(latitude: 51.5, longitude: -0.12), sequel: nil, writers: [], editor: nil
    )
    context.insert(novel)
    try context.save()

    let loaded = try #require(try context.record(id: novel.id, for: Novel.self))
    #expect(loaded.title == "Dune")
    #expect(loaded.tags == ["sf", "classic"])
    #expect(loaded.year == 1965)
    #expect(loaded.note == "secret")
    #expect(loaded.shop?.latitude == 51.5)
}

@MainActor
@Test func recordFillsReferenceIDsInOrder() throws {
    let context = try makeContext(for: Page.self)
    let labels = ["a", "b", "c"].map { Label(name: $0) }
    let page = Page(title: "Notes", labels: [labels[2], labels[0], labels[1]])
    context.insert(page)
    try context.save()

    let loaded = try #require(try context.record(id: page.id, for: Page.self))
    #expect(referenceIDs(loaded, "labels") == [labels[2].uuid, labels[0].uuid, labels[1].uuid])
}

/// A record reads as saved until `save()`.
@MainActor
@Test func recordReturnsTheSavedRecord() throws {
    let context = try makeContext(for: Venue.self)
    var venue = makeVenue()
    context.insert(venue)
    #expect(try context.record(id: venue.id, for: Venue.self) == nil)
    try context.save()
    let saved = venue
    #expect(try context.record(id: venue.id, for: Venue.self) == saved)

    venue.name = "Arena"
    context.insert(venue)
    #expect(try context.record(id: venue.id, for: Venue.self) == saved)
    try context.save()
    #expect(try context.record(id: venue.id, for: Venue.self)?.name == "Arena")

    context.delete(venue)
    #expect(try context.record(id: venue.id, for: Venue.self)?.name == "Arena")
    try context.save()
    #expect(try context.record(id: venue.id, for: Venue.self) == nil)
    #expect(try context.record(id: venue.id) == nil)
}

@MainActor
@Test func recordIsNilWhenMissingDeletedOrInAnotherZone() throws {
    let context = try makeContext(for: Page.self)
    let page = Page(title: "Notes", labels: [])
    #expect(try context.record(id: page.id, for: Page.self) == nil)
    context.insert(page)
    try context.save()

    context.zone = "Work"
    #expect(try context.record(id: page.id, for: Page.self) == nil)
    #expect(try context.record(id: page.id) == nil)

    context.zone = .records
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00'", [])
    context.delete(page)
    try context.save()
    #expect(try context.record(id: page.id, for: Page.self) == nil)
    #expect(try context.record(id: page.id) == nil)
}

/// Without a type, the record is found in whichever table holds it.
@MainActor
@Test func recordFindsTheTypeFromTheID() throws {
    let context = try makeContext(for: Page.self, Venue.self)
    let label = Label(name: "a")
    let venue = makeVenue()
    context.insert(label)
    context.insert(venue)
    try context.save()

    #expect((try context.record(id: venue.id) as? Venue) == venue)
    #expect((try context.record(id: label.id) as? Label) == label)
    #expect(try context.record(id: UUID()) == nil)
}

// MARK: - New targets

/// A loaded target that exists nowhere yet is inserted with the record that refers to it, in
/// the same zone.
@MainActor
@Test func saveInsertsNewTargets() throws {
    let context = try makeContext(for: Page.self)
    context.zone = "Work"
    let labels = ["a", "b"].map { Label(name: $0) }
    context.insert(Page(title: "Notes", labels: labels))
    #expect(context.changes.count == 1)
    try context.save()

    for label in labels {
        #expect(try currentRow("Label", label.id, in: context, zone: "Work")["name"] == .text(label.name))
    }
}

/// A target that is already saved is never written, so a stale copy can't overwrite it.
@MainActor
@Test func saveLeavesExistingTargetsAlone() throws {
    let context = try makeContext(for: Page.self)
    let label = Label(name: "Current")
    context.insert(label)
    try context.save()

    let stale = Label(name: "Stale", id: label.id)
    context.insert(Page(title: "Notes", labels: [stale]))
    try context.save()
    #expect(try currentRow("Label", label.id, in: context)["name"] == .text("Current"))
}

/// A target staged on its own is saved as staged, not as the copy the record holds.
@MainActor
@Test func stagedTargetsWinOverLoadedCopies() throws {
    let context = try makeContext(for: Page.self)
    let label = Label(name: "Loaded")
    context.insert(Page(title: "Notes", labels: [label]))
    context.insert(Label(name: "Staged", id: label.id))
    try context.save()
    #expect(try currentRow("Label", label.id, in: context)["name"] == .text("Staged"))
}

/// A deleted target stays deleted.
@MainActor
@Test func saveDoesNotRestoreDeletedTargets() throws {
    let context = try makeContext(for: Page.self)
    let label = Label(name: "a")
    context.insert(label)
    try context.save()
    try context.database.run("UPDATE \"Label\" SET \"_systemFields\" = x'00'", [])
    context.delete(label)
    try context.save()

    context.insert(Page(title: "Notes", labels: [label]))
    try context.save()
    #expect(try currentRow("Label", label.id, in: context)["_deleted"] == .integer(1))
}

/// New targets' own new targets are inserted too, through to-one and to-many references.
@MainActor
@Test func saveInsertsNewTargetsAtEveryLevel() throws {
    let context = try makeContext(for: Novel.self)
    let writer = Writer(name: "Herbert", bookIDs: [])
    let sequel = Novel(
        title: "Dune Messiah", subtitle: nil, tags: [], year: 1969, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [writer], editor: nil
    )
    let novel = Novel(
        title: "Dune", subtitle: nil, tags: [], year: 1965, note: nil,
        cover: nil, shop: nil, sequel: sequel, writers: [], editor: nil
    )
    context.insert(novel)
    try context.save()

    #expect(try currentRow("Novel", sequel.id, in: context)["title"] == .text("Dune Messiah"))
    #expect(try currentRow("Writer", writer.id, in: context)["name"] == .text("Herbert"))
    #expect(try linkRows(of: sequel.id, in: context).map { $0["targetName"] } == [Optional(SQLValue.text(writer.id.uuidString))])
}

