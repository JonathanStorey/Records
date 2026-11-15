import Foundation
import Synchronization
import Testing
@testable import Records

// Every read returns records whose references hold records, and those records' references
// hold IDs.

/// The IDs a reference holds.
private func ids(_ record: some Record, _ property: String) -> [UUID] {
    record.referenceStates.first { $0.property == property }?.ids ?? []
}

@MainActor
private func savedShelf() throws -> (RecordContext, [Musician], [LP]) {
    let nova = Musician(name: "Nova", isActive: true)
    let echo = Musician(name: "Echo", isActive: false)
    let lps = [
        LP(title: "A", year: 1999, musician: nova, cuts: [
            Cut(title: "Bloom", seconds: 200), Cut(title: "Drift", seconds: 350),
        ]),
        LP(title: "B", year: 2004, musician: echo, cuts: [Cut(title: "Ash", seconds: 100)]),
        LP(title: "C", year: 2010, musician: nil, cuts: []),
    ]
    let context = try RecordContainer(for: [Review.self, LP.self, Musician.self, Cut.self], url: nil).mainContext
    for lp in lps { context.insert(lp) }
    try context.save()
    return (context, [nova, echo], lps)
}

@MainActor
@Test func fetchedRecordsHoldTheirReferences() throws {
    let (context, _, lps) = try savedShelf()
    let fetched = try context.fetch(RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)]))

    #expect(fetched.map(\.id) == lps.map(\.id))
    #expect(fetched.map { $0.musician?.name } == ["Nova", "Echo", nil])
    #expect(fetched.map { $0.cuts.map(\.title) } == [["Bloom", "Drift"], ["Ash"], []])
    #expect(fetched.allSatisfy { $0.$musician.isLoaded && $0.$cuts.isLoaded })
}

/// Loading stops one level deep: the loaded records' own references hold IDs.
@MainActor
@Test func loadedRecordsHoldIDs() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(stars: 5, lp: lps[0]))
    try context.save()

    let review = try #require(try context.fetch(RecordDescriptor<Review>()).first)
    let lp = try #require(review.lp)
    #expect(lp.title == "A")
    #expect(review.$lp.isLoaded)
    #expect(!lp.$musician.isLoaded && !lp.$cuts.isLoaded)
    #expect(lp.$musician.id == lps[0].musician?.id)
    #expect(lp.$cuts.count == 2)
}

/// A read by ID loads the same way, with or without the type.
@MainActor
@Test func aRecordReadByIDHoldsItsReferences() throws {
    let (context, _, lps) = try savedShelf()
    let lp = try #require(try context.record(id: lps[0].id, for: LP.self))
    #expect(lp.musician?.name == "Nova")
    #expect(lp.cuts.map(\.title) == ["Bloom", "Drift"])

    let any = try #require(try context.record(id: lps[1].uuid) as? LP)
    #expect(any.musician?.name == "Echo")
}

/// A fetch sees changes to the targets once they are saved, with a limit the database applies.
@MainActor
@Test func loadedTargetsSeeChangesOnlyAfterSave() throws {
    let (context, musicians, _) = try savedShelf()
    var renamed = musicians[0]
    renamed.name = "Nova (Live)"
    context.insert(renamed)

    let descriptor = RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)], fetchLimit: 1)
    #expect(try context.fetch(descriptor).map { $0.musician?.name } == ["Nova"])

    try context.save()
    #expect(try context.fetch(descriptor).map { $0.musician?.name } == ["Nova (Live)"])
}

/// A fetch whose predicate reads through references returns records loaded one level deep too.
@MainActor
@Test func aPathFetchHoldsReferencesOneLevelDeep() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(stars: 5, lp: lps[0]))
    context.insert(Review(stars: 3, lp: lps[1]))
    try context.save()

    let reviews = try context.fetch(RecordDescriptor<Review>(predicate: #Predicate { $0.lp?.musician?.name == "Nova" }))
    #expect(reviews.map { $0.lp?.title } == ["A"])
    #expect(reviews.first?.lp?.$musician.isLoaded == false)
    #expect(reviews.first.map { ids($0, "lp") } == [lps[0].uuid])
}

/// A reference with no target counts as loaded.
@MainActor
@Test func anEmptyReferenceIsLoaded() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(stars: 1, lp: nil))
    try context.save()

    let review = try #require(try context.fetch(RecordDescriptor<Review>()).first)
    #expect(review.$lp.isLoaded)
    let unloaded = try #require(try context.fetch(RecordDescriptor<LP>(predicate: #Predicate { $0.year == 2010 })).first)
    #expect(unloaded.id == lps[2].id)
    #expect(unloaded.$musician.isLoaded && unloaded.$cuts.isLoaded)
}

#if DEBUG
/// A debug build warns once about a reference that holds IDs but none of their records, and
/// never about one with no targets.
@Test func readingAnUnloadedReferenceWarns() {
    _ = ToMany<Cut>(ids: []).read(LP.self, "emptyProbe")
    _ = ToOne<Musician>(id: nil).read(LP.self, "emptyOneProbe")
    #expect(!UnloadedReference.warned.withLock { $0.contains("LP.emptyProbe") || $0.contains("LP.emptyOneProbe") })

    _ = ToMany<Cut>(ids: [Cut.ID(rawValue: UUID())]).read(LP.self, "unloadedProbe")
    _ = ToOne<Musician>(id: Musician.ID(rawValue: UUID())).read(LP.self, "unloadedOneProbe")
    #expect(UnloadedReference.warned.withLock { $0.isSuperset(of: ["LP.unloadedProbe", "LP.unloadedOneProbe"]) })
}
#endif
