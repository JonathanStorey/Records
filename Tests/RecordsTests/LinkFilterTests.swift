import Foundation
import Testing
@testable import Records

// Filters on references that hold IDs, which the database checks through links.

@MainActor
private func context(for types: any Record.Type...) throws -> RecordContext {
    try RecordContainer(for: types, url: nil).mainContext
}

/// Checks that fetching with each predicate matches evaluating it in Swift over every saved
/// record, and that the predicate translates exactly.
@MainActor
private func expectMatches<R: Record>(
    _ predicates: [Predicate<R>], in context: RecordContext, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let saved = try context.fetch(RecordDescriptor<R>())
    let translator = PredicateTranslator(for: R.self)
    for (index, predicate) in predicates.enumerated() {
        let expected = Set(try saved.filter { try predicate.evaluate($0) }.map(\.id))
        let fetched = Set(try context.fetch(RecordDescriptor(predicate: predicate)).map(\.id))
        #expect(fetched == expected, "predicate \(index)", sourceLocation: sourceLocation)
        #expect(translator.translate(predicate)?.isExact == true, "predicate \(index)", sourceLocation: sourceLocation)
    }
}

@MainActor
@Test func filtersOnAToOneIDReference() throws {
    let context = try context(for: Account.self, Settings.self)
    let settings = (0..<3).map { _ in Settings(accountID: nil) }
    let accounts = [
        Account(settings: settings[0]),
        Account(settings: settings[1]),
        Account(settings: nil),
    ]
    for account in accounts { context.insert(account) }
    context.insert(settings[2])
    try context.save()

    let owner = accounts[0].id
    let either: [Account.ID?] = [accounts[0].id, accounts[2].id]
    let missing = Account.ID()
    try expectMatches([
        #Predicate<Settings> { $0.accountID == owner },
        #Predicate<Settings> { $0.accountID != owner },
        #Predicate<Settings> { $0.accountID == nil },
        #Predicate<Settings> { $0.accountID != nil },
        #Predicate<Settings> { $0.accountID == missing },
        #Predicate<Settings> { either.contains($0.accountID) },
        #Predicate<Settings> { !($0.accountID == owner) && $0.accountID != nil },
    ], in: context)
    #expect(try context.fetch(RecordDescriptor<Settings>(predicate: #Predicate { $0.accountID == owner })).map(\.id)
        == [settings[0].id])
}

@MainActor
@Test func filtersOnToManyIDReferences() throws {
    let context = try context(for: Book.self, Shelf.self)
    let shelves = (0..<3).map { Shelf(name: "\($0)", bookIDs: []) }
    for shelf in shelves { context.insert(shelf) }
    let books = [
        Book(title: "x", shelf: shelves[0]),
        Book(title: "y", shelf: shelves[0]),
        Book(title: "z", shelf: shelves[1]),
    ]
    for book in books { context.insert(book) }
    try context.save()

    let first = books[0].id, second = books[1].id, third = books[2].id, missing = Book.ID()
    try expectMatches([
        #Predicate<Shelf> { $0.bookIDs.contains(first) },
        #Predicate<Shelf> { $0.bookIDs.contains(third) },
        #Predicate<Shelf> { $0.bookIDs.contains(missing) },
        #Predicate<Shelf> { !$0.bookIDs.contains(second) },
        #Predicate<Shelf> { $0.bookIDs.contains(first) || $0.bookIDs.contains(third) },
    ], in: context)
}

@MainActor
@Test func filtersOnTheFromSideOfAToManyOwner() throws {
    let context = try context(for: Release.self, Song.self)
    let songs = (0..<3).map { Song(title: "\($0)", albumID: nil) }
    let release = Release(tracks: [songs[0], songs[1]])
    context.insert(release)
    context.insert(songs[2])
    try context.save()

    let id = release.id
    try expectMatches([
        #Predicate<Song> { $0.albumID == id },
        #Predicate<Song> { $0.albumID == nil },
    ], in: context)
}

@MainActor
@Test func idFiltersSeeChangesOnlyAfterSave() throws {
    let context = try context(for: Account.self, Settings.self)
    let settings = Settings(accountID: nil)
    var account = Account(settings: settings)
    context.insert(account)
    try context.save()

    // An unsaved edit drops the link, and the filter sees it only after the save.
    account._settings.value = nil
    context.insert(account)
    let id = account.id
    let linked = RecordDescriptor<Settings>(predicate: #Predicate { $0.accountID == id })
    let unlinked = RecordDescriptor<Settings>(predicate: #Predicate { $0.accountID == nil })
    #expect(try context.fetch(linked).map(\.id) == [settings.id])
    #expect(try context.fetchCount(unlinked) == 0)

    try context.save()
    #expect(try context.fetch(linked).isEmpty)
    #expect(try context.fetchCount(unlinked) == 1)
}

@Test func anIDFilterIsALinkCondition() throws {
    let id = Account.ID()
    let result = try #require(PredicateTranslator(for: Settings.self).translate(#Predicate<Settings> { $0.accountID == id }))
    #expect(result.filter.sql.hasPrefix("EXISTS (SELECT 1 FROM \"RecordLink\" AS \"l1\""))
    #expect(result.filter.values.contains(.text("Account.settings")))
    #expect(result.filter.values.contains(.text(id.uuidString)))
    #expect(result.isExact)
}
