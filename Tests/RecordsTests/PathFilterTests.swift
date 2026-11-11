import Foundation
import Testing
@testable import Records

// Filters that read through references to records, at any depth.

@Record
struct Musician: Codable, Equatable {
    var id: UUID
    var name: String
    var isActive: Bool
}

@Record
struct Cut: Codable, Equatable {
    var id: UUID
    var title: String
    var seconds: Int
}

@Record
struct LP: Codable, Equatable {
    var id: UUID
    var title: String
    var year: Int
    @Reference var musician: Musician?
    @Reference var cuts: [Cut]
}

@Record
struct Review: Codable, Equatable {
    var id: UUID
    var stars: Int
    @Reference var lp: LP?
}

/// Musicians, records, and reviews, with every reference loaded, as saved.
private struct Library {
    let musicians: [Musician]
    let lps: [LP]
    let reviews: [Review]

    init() {
        let nova = Musician(id: UUID(), name: "Nova", isActive: true)
        let echo = Musician(id: UUID(), name: "Echo", isActive: false)
        let cafe = Musician(id: UUID(), name: "Cafe\u{301}", isActive: true)
        musicians = [nova, echo, cafe]
        let cut = { (title: String, seconds: Int) in Cut(id: UUID(), title: title, seconds: seconds) }
        lps = [
            LP(id: UUID(), title: "A", year: 1999, musician: nova, cuts: [cut("Bloom", 200), cut("Drift", 350)]),
            LP(id: UUID(), title: "B", year: 2004, musician: echo, cuts: [cut("Ash", 100)]),
            LP(id: UUID(), title: "C", year: 2010, musician: nil, cuts: []),
            LP(id: UUID(), title: "D", year: 2015, musician: nova, cuts: [cut("Tide", 450)]),
            LP(id: UUID(), title: "E", year: 2020, musician: cafe, cuts: [cut("Bloom", 250)]),
        ]
        reviews = [
            Review(id: UUID(), stars: 5, lp: lps[0]),
            Review(id: UUID(), stars: 3, lp: lps[1]),
            Review(id: UUID(), stars: 4, lp: nil),
            Review(id: UUID(), stars: 2, lp: lps[2]),
            Review(id: UUID(), stars: 1, lp: lps[4]),
        ]
    }

    @MainActor
    func save() throws -> RecordContext {
        let context = try RecordContainer(for: [Review.self, LP.self, Musician.self, Cut.self], url: nil).mainContext
        for review in reviews { context.insert(review) }
        for lp in lps { context.insert(lp) }
        try context.save()
        return context
    }
}

/// Checks that fetching with each predicate returns the records it matches in `records`, which
/// hold every record their paths reach.
@MainActor
private func expectMatches<R: Record>(
    _ predicates: [Predicate<R>], in records: [R], context: RecordContext, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    for (index, predicate) in predicates.enumerated() {
        let expected = Set(try records.filter { try predicate.evaluate($0) }.map(\.id))
        let fetched = try context.fetch(RecordDescriptor(predicate: predicate)).map(\.id)
        #expect(Set(fetched) == expected, "predicate \(index)", sourceLocation: sourceLocation)
        #expect(fetched.count == expected.count, "predicate \(index)", sourceLocation: sourceLocation)
        #expect(try context.fetchCount(RecordDescriptor(predicate: predicate)) == expected.count, "predicate \(index)", sourceLocation: sourceLocation)
    }
}

private let lpPredicates: [Predicate<LP>] = [
    #Predicate { $0.musician?.name == "Nova" },
    #Predicate { $0.musician?.name != "Nova" },
    #Predicate { $0.musician?.name == "Café" },
    #Predicate { $0.musician == nil },
    #Predicate { $0.musician != nil },
    #Predicate { $0.musician?.isActive == true },
    #Predicate { $0.musician?.isActive == false },
    #Predicate { $0.year > 2000 && $0.musician?.name == "Nova" },
    #Predicate { $0.year < 2000 || $0.musician?.name == "Echo" },
    #Predicate { $0.musician?.name.contains("ov") == true },
    #Predicate { $0.cuts.contains { $0.title == "Bloom" } },
    #Predicate { $0.cuts.contains { $0.seconds > 300 } },
    #Predicate { !$0.cuts.contains { $0.seconds > 300 } },
    #Predicate { $0.cuts.allSatisfy { $0.seconds < 400 } },
    #Predicate { $0.cuts.contains { $0.title.contains("oo") } },
    #Predicate { $0.cuts.contains { $0.seconds > 300 } && $0.musician?.isActive == true },
]

private let reviewPredicates: [Predicate<Review>] = [
    #Predicate { $0.lp?.musician?.name == "Nova" },
    #Predicate { $0.lp?.musician?.name != "Nova" },
    #Predicate { $0.lp?.musician == nil },
    #Predicate { $0.lp?.year == 2004 },
    #Predicate { $0.lp == nil },
    #Predicate { ($0.lp?.cuts.contains { $0.seconds > 300 }) ?? false },
    #Predicate { ($0.lp?.cuts.contains { $0.title == "Bloom" }) == true },
    #Predicate { $0.stars > 2 && $0.lp?.musician?.isActive == true },
]

@MainActor
@Test func filtersThroughReferencesToRecords() throws {
    let library = Library()
    let context = try library.save()
    try expectMatches(lpPredicates, in: library.lps, context: context)
}

@MainActor
@Test func filtersThroughTwoLevelsOfReferences() throws {
    let library = Library()
    let context = try library.save()
    try expectMatches(reviewPredicates, in: library.reviews, context: context)
}

@Test func pathsTranslateExactlyWhereTheirTestsDo() {
    let translator = PredicateTranslator(for: Review.self)
    #expect(translator.translate(#Predicate<Review> { $0.lp?.year == 2004 })?.isExact == true)
    #expect(translator.translate(#Predicate<Review> { $0.lp?.musician == nil })?.isExact == true)
    #expect(translator.translate(#Predicate<Review> { ($0.lp?.cuts.contains { $0.seconds > 300 }) ?? false })?.isExact == true)
    #expect(translator.translate(#Predicate<Review> { $0.lp?.musician?.name == "Nova" })?.isExact == false)

    let lps = PredicateTranslator(for: LP.self)
    #expect(lps.translate(#Predicate<LP> { $0.cuts.allSatisfy { $0.seconds < 400 } })?.isExact == true)
    #expect(lps.translate(#Predicate<LP> { $0.cuts.contains { $0.title.contains("oo") } })?.isExact == false)
    #expect(lps.translate(#Predicate<LP> { $0.musician?.name.contains("ov") == true }) == nil)
}

@MainActor
@Test func fetchedRecordsStillHoldIDs() throws {
    let library = Library()
    let context = try library.save()
    let lps = try context.fetch(RecordDescriptor<LP>(predicate: #Predicate { $0.musician?.name.contains("ov") == true }))
    let fetched = Set(lps.map(\.id))
    let expected: Set<UUID> = [library.lps[0].id, library.lps[3].id]
    #expect(fetched == expected)
    for lp in lps {
        #expect(lp.musician == nil)
        #expect(lp.referenceStates.first { $0.property == "musician" }?.ids == [library.musicians[0].id])
    }
}

@MainActor
@Test func aMissingTargetIsNotReached() throws {
    let library = Library()
    let context = try library.save()
    // Deleting a musician leaves the records' links to it, which reach nothing.
    context.delete(library.musicians[1])
    try context.save()
    let echo = #Predicate<LP> { $0.musician?.name == "Echo" }
    let none = #Predicate<LP> { $0.musician == nil }
    #expect(try context.fetch(RecordDescriptor(predicate: echo)).isEmpty)
    #expect(Set(try context.fetch(RecordDescriptor(predicate: none)).map(\.title)) == ["B", "C"])
}

@MainActor
@Test func pathsSeeChangesAtEveryLevelOnlyAfterSave() throws {
    let library = Library()
    let context = try library.save()
    let nova = #Predicate<Review> { $0.lp?.musician?.name == "Nova" }
    let noLP = #Predicate<Review> { $0.lp == nil }
    let before = Set(try context.fetch(RecordDescriptor(predicate: nova)).map(\.stars))
    let beforeNoLP = Set(try context.fetch(RecordDescriptor(predicate: noLP)).map(\.stars))

    // An unsaved rename two levels down, an unsaved delete one level down,
    // and an unsaved record at the top pointing at an unsaved record.
    var echo = library.musicians[1]
    echo.name = "Nova"
    context.insert(echo)
    context.delete(library.lps[0])
    let newcomer = LP(id: UUID(), title: "F", year: 2024, musician: echo, cuts: [])
    context.insert(newcomer)
    context.insert(Review(id: UUID(), stars: 4, lp: newcomer))

    #expect(Set(try context.fetch(RecordDescriptor(predicate: nova)).map(\.stars)) == before)
    #expect(Set(try context.fetch(RecordDescriptor(predicate: noLP)).map(\.stars)) == beforeNoLP)

    // Saved, every level answers with the changes.
    try context.save()
    #expect(Set(try context.fetch(RecordDescriptor(predicate: nova)).map(\.stars)) == [3, 4])
    #expect(try context.fetchCount(RecordDescriptor(predicate: nova)) == 2)
    #expect(Set(try context.fetch(RecordDescriptor(predicate: noLP)).map(\.stars)) == [5, 4])
}

@MainActor
@Test func pathsSortAndLimit() throws {
    let library = Library()
    let context = try library.save()
    let descriptor = RecordDescriptor<LP>(
        predicate: #Predicate { $0.cuts.contains { $0.title.contains("o") } },
        sortBy: [SortDescriptor(\.year, order: .reverse)],
        fetchLimit: 2
    )
    #expect(try context.fetch(descriptor).map(\.title) == ["E", "A"])
}
