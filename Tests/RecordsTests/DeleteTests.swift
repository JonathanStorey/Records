import Foundation
import Testing
@testable import Records

// Deleting a record removes the links that point at it, and deletes the records it owns through
// a reference whose `from:` side says `deleteSelf: true`.

@MainActor
private func makeContext() throws -> RecordContext {
    try RecordContainer(for: [Release.self, Song.self, Shelf.self, Book.self, Page.self], url: nil).mainContext
}

/// The IDs a reference holds.
private func ids(_ record: some Record, _ property: String) -> [UUID] {
    record.referenceStates.first { $0.property == property }?.ids ?? []
}

/// The current, undeleted links that point at `id`.
@MainActor
private func linksTo<R>(_ id: RecordID<R>, in context: RecordContext) throws -> Int {
    try context.database.rows(
        "SELECT * FROM \"RecordLink\" WHERE \"targetName\" = ? AND \"_isCurrent\" = 1 AND \"_deleted\" = 0",
        [.text(id.uuidString)]
    ).count
}

@MainActor
@Test func deletingATargetDropsItFromReferencesToIt() throws {
    let context = try makeContext()
    let labels = ["a", "b"].map { Label(name: $0) }
    let page = Page(title: "Notes", labels: labels)
    context.insert(page)
    try context.save()

    context.delete(labels[0])
    try context.save()

    #expect(try linksTo(labels[0].id, in: context) == 0)
    let saved = try #require(try context.record(id: page.id, for: Page.self))
    #expect(ids(saved, "labels") == [labels[1].uuid])
}

@MainActor
@Test func deletingTheOneSideOfAManyOwnedLinkClearsIt() throws {
    let context = try makeContext()
    let shelf = Shelf(name: "Fiction", bookIDs: [])
    let book = Book(title: "Dune", shelf: shelf)
    context.insert(shelf)
    context.insert(book)
    try context.save()

    context.delete(shelf)
    try context.save()

    let saved = try #require(try context.record(id: book.id, for: Book.self))
    #expect(ids(saved, "shelf").isEmpty)
}

@MainActor
@Test func deleteSelfDeletesOwnedRecordsWithTheirOwner() throws {
    let context = try makeContext()
    let songs = ["One", "Two"].map { Song(title: $0, albumID: nil) }
    let release = Release(tracks: songs)
    context.insert(release)
    try context.save()
    #expect(try context.fetch(RecordDescriptor<Song>()).count == 2)

    context.delete(release)
    try context.save()

    #expect(try context.fetch(RecordDescriptor<Song>()).isEmpty)
    #expect(try linksTo(songs[0].id, in: context) == 0)
}

/// A record moved to another owner in the same save stays.
@MainActor
@Test func deleteSelfSparesRecordsMovedInTheSameSave() throws {
    let context = try makeContext()
    let songs = ["One", "Two"].map { Song(title: $0, albumID: nil) }
    let old = Release(tracks: songs)
    context.insert(old)
    try context.save()

    context.insert(Release(tracks: [songs[1]]))
    context.delete(old)
    try context.save()

    #expect(try context.fetch(RecordDescriptor<Song>()).map(\.title) == ["Two"])
}

/// Deleting a record that doesn't say `deleteSelf` leaves the records it points at.
@MainActor
@Test func deletingAnOwnerWithoutDeleteSelfKeepsItsTargets() throws {
    let context = try makeContext()
    let labels = ["a", "b"].map { Label(name: $0) }
    let page = Page(title: "Notes", labels: labels)
    context.insert(page)
    try context.save()

    context.delete(page)
    try context.save()

    #expect(try context.fetch(RecordDescriptor<Label>()).count == 2)
}

// MARK: - Deleting by type

@MainActor
@Test func deletingByTypeDeletesEveryRecordOfIt() throws {
    let context = try makeContext()
    for title in ["Dune", "Emma", "Ulysses"] {
        context.insert(Book(title: title, shelf: nil))
    }
    context.insert(Shelf(name: "Fiction", bookIDs: []))
    try context.save()

    #expect(try context.delete(Book.self) == 3)
    #expect(try context.fetchCount(RecordDescriptor<Book>()) == 3, "nothing is deleted until the save")
    try context.save()
    #expect(try context.fetchCount(RecordDescriptor<Book>()) == 0)
    #expect(try context.fetchCount(RecordDescriptor<Shelf>()) == 1)
}

@MainActor
@Test func deletingByTypeDeletesOnlyTheMatches() throws {
    let context = try makeContext()
    for title in ["Dune", "Emma", "Ulysses"] {
        context.insert(Book(title: title, shelf: nil))
    }
    try context.save()

    #expect(try context.delete(Book.self, where: #Predicate { $0.title == "Emma" }) == 1)
    try context.save()
    #expect(try context.fetch(RecordDescriptor<Book>(sortBy: [SortDescriptor(\.title)])).map(\.title) == ["Dune", "Ulysses"])
}

@MainActor
@Test func deletingByTypeCascadesLikeDeletingEach() throws {
    let context = try makeContext()
    let songs = ["Intro", "Outro"].map { Song(title: $0, albumID: nil) }
    context.insert(Release(tracks: songs))
    try context.save()

    try context.delete(Release.self)
    try context.save()
    #expect(try context.fetchCount(RecordDescriptor<Song>()) == 0)
}
