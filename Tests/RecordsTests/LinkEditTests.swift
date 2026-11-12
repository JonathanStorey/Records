import Foundation
import Testing
@testable import Records

// Adding and removing one target through `insert(_:into:of:)` and `remove(_:from:of:)`.

@MainActor
private func context() throws -> RecordContext {
    try RecordContainer(for: [Page.self, Book.self, Shelf.self, Release.self, Song.self], url: nil).mainContext
}

@MainActor
private func savedPage(_ labels: [Label], in context: RecordContext) throws -> Page {
    let page = Page(id: UUID(), title: "Notes", labels: labels)
    context.insert(page)
    try context.save()
    return page
}

@MainActor
private func labelIDs(of page: Page, in context: RecordContext) throws -> [UUID] {
    try #require(try context.record(id: page.id, for: Page.self)).$labels.ids
}

private func labels(_ names: String...) -> [Label] {
    names.map { Label(id: UUID(), name: $0) }
}

@MainActor
@Test func insertAddsATargetAfterTheRest() throws {
    let context = try context()
    let items = labels("a", "b", "c")
    let page = try savedPage([items[0]], in: context)

    context.insert(items[1], into: \Page.labels, of: page.id)
    context.insert([items[2]], into: \Page.labels, of: page.id)
    try context.save()

    #expect(try labelIDs(of: page, in: context) == items.map(\.id))
    #expect(try context.record(id: items[2].id, for: Label.self) == items[2])
}

@MainActor
@Test func insertWritesOnlyTheLink() throws {
    let context = try context()
    let page = try savedPage([], in: context)
    let modified = try context.database.currentRow(of: RecordKey(recordType: "Page", name: page.id.uuidString, zone: context.zone))?["_modifiedAt"]

    context.insert(Label(id: UUID(), name: "a"), into: \Page.labels, of: page.id)
    try context.save()

    let row = try context.database.currentRow(of: RecordKey(recordType: "Page", name: page.id.uuidString, zone: context.zone))
    #expect(row?["_modifiedAt"] == modified)
}

@MainActor
@Test func insertingAHeldTargetKeepsItsPlace() throws {
    let context = try context()
    let items = labels("a", "b")
    let page = try savedPage(items, in: context)

    context.insert(items[0], into: \Page.labels, of: page.id)
    #expect(!context.hasChanges)
    #expect(try labelIDs(of: page, in: context) == items.map(\.id))
}

@MainActor
@Test func insertNeverOverwritesASavedTarget() throws {
    let context = try context()
    let label = Label(id: UUID(), name: "a")
    let page = try savedPage([], in: context)
    context.insert(label)
    try context.save()

    context.insert(Label(id: label.id, name: "stale"), into: \Page.labels, of: page.id)
    try context.save()

    #expect(try context.record(id: label.id, for: Label.self)?.name == "a")
    #expect(try labelIDs(of: page, in: context) == [label.id])
}

@MainActor
@Test func removeDeletesOnlyTheLink() throws {
    let context = try context()
    let items = labels("a", "b", "c")
    let page = try savedPage(items, in: context)

    context.remove(items[0].id, from: \Page.labels, of: page.id)
    context.remove([items[2].id, UUID()], from: \Page.labels, of: page.id)
    try context.save()

    #expect(try labelIDs(of: page, in: context) == [items[1].id])
    #expect(try context.record(id: items[0].id, for: Label.self) == items[0])
}

@MainActor
@Test func removingAPendingInsertLeavesNothing() throws {
    let context = try context()
    let page = try savedPage([], in: context)
    let label = Label(id: UUID(), name: "a")

    context.insert(label, into: \Page.labels, of: page.id)
    context.remove(label.id, from: \Page.labels, of: page.id)
    try context.save()

    #expect(try labelIDs(of: page, in: context).isEmpty)
}

@MainActor
@Test func aLinkSurvivesANewOwnerSavedWithIt() throws {
    let context = try context()
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: [items[0]])

    context.insert(items[1], into: \Page.labels, of: page.id)
    context.insert(page)
    try context.save()

    #expect(Set(try labelIDs(of: page, in: context)) == Set(items.map(\.id)))
}

@MainActor
@Test func toOneInsertReplacesTheTarget() throws {
    let context = try context()
    let shelves = (0..<2).map { Shelf(id: UUID(), name: "\($0)", bookIDs: []) }
    let book = Book(id: UUID(), title: "Dune", shelf: shelves[0])
    context.insert(book)
    context.insert(shelves[1])
    try context.save()

    context.insert(shelves[1], into: \Book.shelf, of: book.id)
    try context.save()

    #expect(try context.record(id: book.id, for: Book.self)?.$shelf.id == shelves[1].id)
    #expect(try context.record(id: shelves[0].id, for: Shelf.self)?.bookIDs == [])
    #expect(try context.record(id: shelves[1].id, for: Shelf.self)?.bookIDs == [book.id])
}

@MainActor
@Test func toOneRemoveClearsOnlyItsOwnTarget() throws {
    let context = try context()
    let shelf = Shelf(id: UUID(), name: "Fiction", bookIDs: [])
    let book = Book(id: UUID(), title: "Dune", shelf: shelf)
    context.insert(book)
    try context.save()

    context.remove(UUID(), from: \Book.shelf, of: book.id)
    #expect(!context.hasChanges)

    context.remove(shelf.id, from: \Book.shelf, of: book.id)
    try context.save()
    #expect(try context.record(id: book.id, for: Book.self)?.$shelf.id == nil)
    #expect(try context.record(id: shelf.id, for: Shelf.self) != nil)
}

@MainActor
@Test func aOneToManyInsertMovesTheTarget() throws {
    let context = try context()
    let song = Song(id: UUID(), title: "Intro", albumID: nil)
    let first = Release(id: UUID(), tracks: [song]), second = Release(id: UUID(), tracks: [])
    context.insert(first)
    context.insert(second)
    try context.save()

    context.insert(song, into: \Release.tracks, of: second.id)
    try context.save()

    #expect(try context.record(id: first.id, for: Release.self)?.$tracks.ids == [])
    #expect(try context.record(id: second.id, for: Release.self)?.$tracks.ids == [song.id])
    #expect(try context.record(id: song.id, for: Song.self)?.albumID == second.id)
}

// MARK: - Through the handles

@MainActor
@Test func theHandleUpdatesTheRecordAndTheContext() throws {
    let context = try context()
    let items = labels("a", "b", "c")
    var page = try savedPage([items[0]], in: context)

    page.$labels.insert([items[1], items[2]], in: context)
    #expect(page.labels == items)
    #expect(page.$labels.ids == items.map(\.id))
    #expect(page.$labels.count == 3)

    page.$labels.remove(atOffsets: IndexSet(integer: 0), in: context)
    #expect(page.$labels.ids == [items[1].id, items[2].id])

    try context.save()
    #expect(try labelIDs(of: page, in: context) == page.$labels.ids)
}

@MainActor
@Test func theHandleRemovesATargetThatIsntLoaded() throws {
    let context = try context()
    let items = labels("a", "b")
    _ = try savedPage(items, in: context)
    let page = try #require(try context.fetch(RecordDescriptor<Page>()).first)
    var bare = try #require(try context.record(id: page.id, for: Page.self))

    bare.$labels.remove(items[0].id, in: context)
    #expect(bare.$labels.ids == [items[1].id])
    try context.save()
    #expect(try labelIDs(of: page, in: context) == [items[1].id])
}

@MainActor
@Test func theToOneHandleSetsAndClears() throws {
    let context = try context()
    let shelves = (0..<2).map { Shelf(id: UUID(), name: "\($0)", bookIDs: []) }
    var book = Book(id: UUID(), title: "Dune", shelf: shelves[0])
    context.insert(book)
    try context.save()

    book.$shelf.set(shelves[1], in: context)
    #expect(book.shelf == shelves[1])
    #expect(book.$shelf.id == shelves[1].id)
    try context.save()
    #expect(try context.record(id: book.id, for: Book.self)?.$shelf.id == shelves[1].id)

    book.$shelf.clear(in: context)
    #expect(book.$shelf.id == nil)
    try context.save()
    #expect(try context.record(id: book.id, for: Book.self)?.$shelf.id == nil)
}
