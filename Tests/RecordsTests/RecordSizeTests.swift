import Foundation
import Testing
@testable import Records

@MainActor
private func makeContext() throws -> RecordContext {
    try RecordContainer(for: [Person.self, Article.self, Poster.self], sync: .inMemory).mainContext
}

private let oversized = String(repeating: "x", count: 1_200_000)

@MainActor
@Test func savingARecordOver1MBThrowsAndWritesNothing() throws {
    let context = try makeContext()
    let small = Person(name: "Fits")
    let large = Person(name: oversized)
    context.insert(small)
    context.insert(large)

    #expect(throws: RecordContextError.recordTooLarge(recordType: "Person", id: large.id.rawValue, bytes: 1_200_004)) {
        try context.save()
    }
    #expect(try context.database.rows("SELECT * FROM \"Person\"").isEmpty)
    #expect(context.hasChanges)

    // Fixing the record lets the same edits save.
    var fixed = large
    fixed.name = "Shorter"
    context.insert(fixed)
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Person\"").count == 2)
}

@MainActor
@Test func editingASavedRecordPast1MBKeepsTheSavedCopy() throws {
    let context = try makeContext()
    var person = Person(name: "Ada")
    context.insert(person)
    try context.save()

    person.name = oversized
    context.insert(person)
    #expect(throws: RecordContextError.self) { try context.save() }
    #expect(try context.record(id: person.id)?.name == "Ada")
}

@MainActor
@Test func aNewTargetOver1MBThrows() throws {
    let context = try makeContext()
    let author = Person(name: oversized)
    context.insert(Article(title: "Long", author: author, editor: nil))

    #expect(throws: RecordContextError.recordTooLarge(recordType: "Person", id: author.id.rawValue, bytes: 1_200_004)) {
        try context.save()
    }
    #expect(try context.database.rows("SELECT * FROM \"Article\"").isEmpty)
}

@MainActor
@Test func aRecordJustUnder1MBSaves() throws {
    let context = try makeContext()
    context.insert(Person(name: String(repeating: "x", count: 1_000_000 - "name".utf8.count)))
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Person\"").count == 1)
}

@MainActor
@Test func anAssetDoesntCountTowardTheLimit() throws {
    let context = try makeContext()
    context.insert(Poster(title: "Tour", image: Data(count: 2_000_000)))
    try context.save()
    #expect(try context.database.rows("SELECT * FROM \"Poster\"").count == 1)
}

@Test func theErrorNamesTheRecordAndItsSize() {
    let id = UUID()
    let error = RecordContextError.recordTooLarge(recordType: "Person", id: id, bytes: 1_200_004)
    #expect(error.description.hasPrefix("Person \(id.uuidString) is 1.2 MB"))
}
