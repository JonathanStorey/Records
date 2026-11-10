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
    let settings = (0..<3).map { _ in Settings(id: UUID(), accountID: nil) }
    for item in settings { context.insert(item) }
    let accounts = [
        Account(id: UUID(), settingsID: settings[0].id),
        Account(id: UUID(), settingsID: settings[1].id),
        Account(id: UUID(), settingsID: nil),
    ]
    for account in accounts { context.insert(account) }
    try context.save()

    let first = settings[0].id
    let either: [UUID?] = [settings[0].id, settings[2].id]
    let missing = UUID()
    try expectMatches([
        #Predicate<Account> { $0.settingsID == first },
        #Predicate<Account> { $0.settingsID != first },
        #Predicate<Account> { $0.settingsID == nil },
        #Predicate<Account> { $0.settingsID != nil },
        #Predicate<Account> { $0.settingsID == missing },
        #Predicate<Account> { either.contains($0.settingsID) },
        #Predicate<Account> { !($0.settingsID == first) && $0.settingsID != nil },
    ], in: context)
    #expect(try context.fetch(RecordDescriptor<Account>(predicate: #Predicate { $0.settingsID == first })).map(\.id)
        == [accounts[0].id])

    // The `from:` side reads the same links from the other end.
    let owner = accounts[1].id
    try expectMatches([
        #Predicate<Settings> { $0.accountID == owner },
        #Predicate<Settings> { $0.accountID == nil },
        #Predicate<Settings> { $0.accountID != owner },
    ], in: context)
}

@MainActor
@Test func filtersOnToManyIDReferences() throws {
    let context = try context(for: Page.self, Book.self, Shelf.self)
    let labels = (0..<3).map { _ in UUID() }
    let pages = [
        Page(id: UUID(), title: "a", labels: [], pinnedIDs: [labels[0], labels[1]]),
        Page(id: UUID(), title: "b", labels: [], pinnedIDs: [labels[1]]),
        Page(id: UUID(), title: "c", labels: [], pinnedIDs: []),
    ]
    for page in pages { context.insert(page) }

    let shelves = (0..<2).map { Shelf(id: UUID(), name: "\($0)", bookIDs: []) }
    for shelf in shelves { context.insert(shelf) }
    let books = [
        Book(id: UUID(), title: "x", shelf: shelves[0]),
        Book(id: UUID(), title: "y", shelf: shelves[0]),
        Book(id: UUID(), title: "z", shelf: nil),
    ]
    for book in books { context.insert(book) }
    try context.save()

    let first = labels[0], second = labels[1], third = labels[2]
    try expectMatches([
        #Predicate<Page> { $0.pinnedIDs.contains(first) },
        #Predicate<Page> { $0.pinnedIDs.contains(second) },
        #Predicate<Page> { $0.pinnedIDs.contains(third) },
        #Predicate<Page> { !$0.pinnedIDs.contains(second) },
        #Predicate<Page> { $0.pinnedIDs.contains(first) || $0.pinnedIDs.contains(third) },
    ], in: context)

    let book = books[1].id
    try expectMatches([
        #Predicate<Shelf> { $0.bookIDs.contains(book) },
        #Predicate<Shelf> { !$0.bookIDs.contains(book) },
    ], in: context)
}

@MainActor
@Test func filtersOnTheFromSideOfAToManyOwner() throws {
    let context = try context(for: Release.self, Song.self)
    let songs = (0..<3).map { Song(id: UUID(), title: "\($0)", albumID: nil) }
    let release = Release(id: UUID(), tracks: [songs[0], songs[1]])
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
@Test func stagedChangesCountForIDFilters() throws {
    let context = try context(for: Account.self, Settings.self)
    let settings = Settings(id: UUID(), accountID: nil)
    var account = Account(id: UUID(), settingsID: settings.id)
    context.insert(settings)
    context.insert(account)
    try context.save()

    // A staged edit drops the link, so the saved row matches in SQL but not in Swift.
    account.settingsID = nil
    context.insert(account)
    let id = settings.id
    #expect(try context.fetch(RecordDescriptor<Account>(predicate: #Predicate { $0.settingsID == id })).isEmpty)
    #expect(try context.fetchCount(RecordDescriptor<Account>(predicate: #Predicate { $0.settingsID == nil })) == 1)
}

@Test func anIDFilterIsALinkCondition() throws {
    let id = UUID()
    let result = try #require(PredicateTranslator(for: Account.self).translate(#Predicate<Account> { $0.settingsID == id }))
    #expect(result.filter.sql.hasPrefix("EXISTS (SELECT 1 FROM \"RecordLink\" AS \"l1\""))
    #expect(result.filter.values == [.text("Account.settingsID"), .text(id.uuidString)])
    #expect(result.isExact)
}
