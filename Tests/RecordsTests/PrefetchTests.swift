import Foundation
import Testing
@testable import Records

// Fetching with `relationshipKeyPathsForPrefetching` returns the named references holding their
// records, loaded together for every result.

/// The IDs a reference holds.
private func ids(_ record: some Record, _ property: String) -> [UUID] {
    record.referenceStates.first { $0.property == property }?.ids ?? []
}

@MainActor
private func savedShelf() throws -> (RecordContext, [Musician], [LP]) {
    let nova = Musician(id: UUID(), name: "Nova", isActive: true)
    let echo = Musician(id: UUID(), name: "Echo", isActive: false)
    let lps = [
        LP(id: UUID(), title: "A", year: 1999, musician: nova, cuts: [
            Cut(id: UUID(), title: "Bloom", seconds: 200), Cut(id: UUID(), title: "Drift", seconds: 350),
        ]),
        LP(id: UUID(), title: "B", year: 2004, musician: echo, cuts: [Cut(id: UUID(), title: "Ash", seconds: 100)]),
        LP(id: UUID(), title: "C", year: 2010, musician: nil, cuts: []),
    ]
    let context = try RecordContainer(for: [Review.self, LP.self, Musician.self, Cut.self], url: nil).mainContext
    for lp in lps { context.insert(lp) }
    try context.save()
    return (context, [nova, echo], lps)
}

@MainActor
@Test func fetchedReferencesHoldIDsWithoutPrefetching() throws {
    let (context, _, lps) = try savedShelf()
    let fetched = try context.fetch(RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)]))
    #expect(fetched.map(\.id) == lps.map(\.id))
    #expect(fetched.allSatisfy { $0.musician == nil && $0.cuts.isEmpty })
    #expect(ids(fetched[0], "musician") == [lps[0].musician!.id])
}

@MainActor
@Test func prefetchingLoadsTheNamedReferences() throws {
    let (context, _, _) = try savedShelf()
    var descriptor = RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)])
    descriptor.relationshipKeyPathsForPrefetching = [\LP.musician, \LP.cuts]
    let fetched = try context.fetch(descriptor)

    #expect(fetched.map { $0.musician?.name } == ["Nova", "Echo", nil])
    #expect(fetched.map { $0.cuts.map(\.title) } == [["Bloom", "Drift"], ["Ash"], []])
}

@MainActor
@Test func prefetchingLoadsOnlyTheReferencesNamed() throws {
    let (context, _, _) = try savedShelf()
    var descriptor = RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)])
    descriptor.relationshipKeyPathsForPrefetching = [\LP.musician]
    let fetched = try context.fetch(descriptor)

    #expect(fetched.map { $0.musician?.name } == ["Nova", "Echo", nil])
    #expect(fetched.allSatisfy { $0.cuts.isEmpty })
}

/// Prefetched records are one level deep: their own references hold IDs.
@MainActor
@Test func prefetchedRecordsHoldIDs() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(id: UUID(), stars: 5, lp: lps[0]))
    try context.save()

    var descriptor = RecordDescriptor<Review>()
    descriptor.relationshipKeyPathsForPrefetching = [\Review.lp]
    let review = try #require(try context.fetch(descriptor).first)
    #expect(review.lp?.title == "A")
    #expect(review.lp?.musician == nil)
    #expect(review.lp.map { ids($0, "musician") } == [lps[0].musician!.id])
}

/// Prefetching works with a limit the database applies and sees staged changes.
@MainActor
@Test func prefetchingSeesStagedChanges() throws {
    let (context, musicians, _) = try savedShelf()
    var renamed = musicians[0]
    renamed.name = "Nova (Live)"
    context.insert(renamed)

    var descriptor = RecordDescriptor<LP>(sortBy: [SortDescriptor(\.year)], fetchLimit: 1)
    descriptor.relationshipKeyPathsForPrefetching = [\LP.musician]
    #expect(try context.fetch(descriptor).map { $0.musician?.name } == ["Nova (Live)"])

    context.rollback()
    #expect(try context.fetch(descriptor).map { $0.musician?.name } == ["Nova"])
}

/// References named on the loaded records' types load too, as deep as they chain.
@MainActor
@Test func prefetchingFollowsReferencesNamedOnLoadedTypes() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(id: UUID(), stars: 5, lp: lps[0]))
    context.insert(Review(id: UUID(), stars: 3, lp: lps[1]))
    try context.save()

    var descriptor = RecordDescriptor<Review>(sortBy: [SortDescriptor(\.stars, order: .reverse)])
    descriptor.relationshipKeyPathsForPrefetching = [\Review.lp, \LP.musician, \LP.cuts]
    let reviews = try context.fetch(descriptor)

    #expect(reviews.map { $0.lp?.title } == ["A", "B"])
    #expect(reviews.map { $0.lp?.musician?.name } == ["Nova", "Echo"])
    #expect(reviews.map { $0.lp?.cuts.map(\.title) } == [["Bloom", "Drift"], ["Ash"]])
}

/// A reference named on a type the chain never reaches loads nothing extra.
@MainActor
@Test func prefetchingIgnoresReferencesOffTheChain() throws {
    let (context, _, lps) = try savedShelf()
    context.insert(Review(id: UUID(), stars: 5, lp: lps[0]))
    try context.save()

    var descriptor = RecordDescriptor<Review>()
    descriptor.relationshipKeyPathsForPrefetching = [\LP.musician]
    let review = try #require(try context.fetch(descriptor).first)
    #expect(review.lp == nil)
    #expect(ids(review, "lp") == [lps[0].id])
}
