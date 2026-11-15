import Foundation
import Testing
@testable import Records

/// A row this app can't read, such as one saved before a field with no default was added, is
/// left out of every read, as if it weren't there.
@MainActor
@Test func anUnreadableRowIsInvisible() throws {
    let context = try RecordContainer(for: [LP.self], url: nil).mainContext
    let broken = Musician(name: "Broken", isActive: true)
    let fine = Musician(name: "Fine", isActive: true)
    let record = LP(title: "Both", year: 2000, musician: broken, cuts: [])
    context.insert(record)
    context.insert(fine)
    try context.save()
    // As if `isActive` had been added, with no default, after this row was saved.
    try context.database.run("UPDATE \"Musician\" SET \"isActive\" = NULL WHERE \"_name\" = ?", [.text(broken.id.uuidString)])

    #expect(try context.fetch(RecordDescriptor<Musician>()).map(\.name) == ["Fine"])
    #expect(try context.fetch(RecordDescriptor<Musician>(sortBy: [SortDescriptor(\.name)])).map(\.name) == ["Fine"])
    #expect(try context.fetchCount(RecordDescriptor<Musician>()) == 1)
    #expect(try context.fetchCount(RecordDescriptor<Musician>(sortBy: [SortDescriptor(\.name)], fetchLimit: 5)) == 1)
    #expect(try context.record(id: broken.id) == nil)

    // A reference to it keeps the ID but holds no record.
    let lp = try #require(try context.record(id: record.id))
    #expect(lp.musician == nil)
    #expect(lp.$musician.id == broken.id)
}
