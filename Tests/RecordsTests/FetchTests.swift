import CloudKit
import Foundation
import Testing
@testable import Records

@MainActor
private func makeContext(for types: any Record.Type...) throws -> RecordContext {
    try RecordContainer(for: types, url: nil).mainContext
}

private func page(_ title: String, labels: [Label] = []) -> Page {
    Page(title: title, labels: labels)
}

private func novel(_ title: String, year: Int, subtitle: String? = nil) -> Novel {
    Novel(
        title: title, subtitle: subtitle, tags: [], year: year, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
    )
}

/// Saves `records` in the context's zone.
@MainActor
private func save(_ records: [some Record], in context: RecordContext) throws {
    for record in records { context.insert(record) }
    try context.save()
}

@MainActor
@Test func fetchReturnsEveryRecordOfTheType() throws {
    let context = try makeContext(for: Page.self)
    try save(["a", "b", "c"].map { page($0) }, in: context)
    #expect(Set(try context.fetch(RecordDescriptor<Page>()).map(\.title)) == ["a", "b", "c"])
    #expect(try context.fetchCount(RecordDescriptor<Page>()) == 3)
}

@MainActor
@Test func fetchFiltersWithAPredicate() throws {
    let context = try makeContext(for: Novel.self)
    try save([novel("Dune", year: 1965), novel("Messiah", year: 1969), novel("Children", year: 1976)], in: context)

    let late = try context.fetch(RecordDescriptor<Novel>(predicate: #Predicate { $0.year > 1966 }))
    #expect(Set(late.map(\.title)) == ["Messiah", "Children"])

    let either = try context.fetch(RecordDescriptor<Novel>(
        predicate: #Predicate { $0.title == "Dune" || $0.title.contains("ild") }
    ))
    #expect(Set(either.map(\.title)) == ["Dune", "Children"])
    #expect(try context.fetchCount(RecordDescriptor<Novel>(predicate: #Predicate { $0.year < 1900 })) == 0)
}

@MainActor
@Test func fetchFiltersOnOptionalFields() throws {
    let context = try makeContext(for: Novel.self)
    try save([novel("Dune", year: 1965, subtitle: "Book One"), novel("Messiah", year: 1969)], in: context)
    let withSubtitle = try context.fetch(RecordDescriptor<Novel>(predicate: #Predicate { $0.subtitle != nil }))
    #expect(withSubtitle.map(\.title) == ["Dune"])
}

@MainActor
@Test func fetchSortsByEveryDescriptor() throws {
    let context = try makeContext(for: Novel.self)
    try save([novel("B", year: 1970), novel("A", year: 1970), novel("C", year: 1960)], in: context)

    let byYearThenTitle = try context.fetch(RecordDescriptor<Novel>(
        sortBy: [SortDescriptor(\.year, order: .reverse), SortDescriptor(\.title)]
    ))
    #expect(byYearThenTitle.map(\.title) == ["A", "B", "C"])
}

@MainActor
@Test func fetchAppliesOffsetAndLimit() throws {
    let context = try makeContext(for: Page.self)
    try save(["a", "b", "c", "d", "e"].map { page($0) }, in: context)
    let sorted = [SortDescriptor(\Page.title)]

    #expect(try context.fetch(RecordDescriptor(sortBy: sorted, fetchLimit: 2)).map(\.title) == ["a", "b"])
    #expect(try context.fetch(RecordDescriptor(sortBy: sorted, fetchLimit: 2, fetchOffset: 2)).map(\.title) == ["c", "d"])
    #expect(try context.fetch(RecordDescriptor(sortBy: sorted, fetchOffset: 4)).map(\.title) == ["e"])
    #expect(try context.fetch(RecordDescriptor(sortBy: sorted, fetchOffset: 9)).isEmpty)
    #expect(try context.fetchCount(RecordDescriptor(sortBy: sorted, fetchLimit: 3)) == 3)
}

/// Changes not yet saved stay out of a fetch until `save()`.
@MainActor
@Test func fetchShowsChangesOnlyAfterSave() throws {
    let context = try makeContext(for: Page.self)
    var edited = page("old")
    let deleted = page("gone")
    try save([edited, deleted, page("kept")], in: context)

    edited.title = "new"
    context.insert(edited)
    context.delete(deleted)
    context.insert(page("added"))

    let sorted = RecordDescriptor<Page>(sortBy: [SortDescriptor(\.title)])
    #expect(try context.fetch(sorted).map(\.title) == ["gone", "kept", "old"])
    #expect(try context.fetch(RecordDescriptor<Page>(predicate: #Predicate { $0.title == "new" })).isEmpty)

    try context.save()
    #expect(try context.fetch(sorted).map(\.title) == ["added", "kept", "new"])
    let matching = try context.fetch(RecordDescriptor<Page>(predicate: #Predicate { $0.title == "new" }))
    #expect(matching.map(\.id) == [edited.id])
}

@MainActor
@Test func fetchLooksOnlyInTheContextsZone() throws {
    let context = try makeContext(for: Page.self)
    try save([page("records")], in: context)
    context.zone = "Work"
    try save([page("work")], in: context)
    context.insert(page("unsaved in work"))
    try context.save()
    context.zone = .records
    context.insert(page("unsaved in records"))
    try context.save()

    let titles = try context.fetch(RecordDescriptor<Page>(sortBy: [SortDescriptor(\.title)])).map(\.title)
    #expect(titles == ["records", "unsaved in records"])
}

@MainActor
@Test func fetchLeavesOutDeletedRecords() throws {
    let context = try makeContext(for: Page.self)
    let gone = page("gone")
    try save([gone, page("kept")], in: context)
    try context.database.run("UPDATE \"Page\" SET \"_systemFields\" = x'00'", [])
    context.delete(gone)
    try context.save()
    #expect(try context.fetch(RecordDescriptor<Page>()).map(\.title) == ["kept"])
}

@MainActor
@Test func fetchFillsReferenceIDs() throws {
    let context = try makeContext(for: Page.self, Novel.self)
    let labels = ["x", "y", "z"].map { Label(name: $0) }
    try save([page("one", labels: [labels[2], labels[0]]), page("two", labels: [labels[1]])], in: context)

    let pages = try context.fetch(RecordDescriptor<Page>(sortBy: [SortDescriptor(\.title)]))
    let ids = pages.map { page in page.referenceStates.first { $0.property == "labels" }?.ids ?? [] }
    #expect(ids == [[labels[2].uuid, labels[0].uuid], [labels[1].uuid]])

    // The `from:` side reads the same links from the other end.
    let writer = Writer(name: "Herbert", bookIDs: [])
    var dune = novel("Dune", year: 1965)
    dune._writers.values = [writer]
    try save([dune], in: context)
    let writers = try context.fetch(RecordDescriptor<Writer>())
    #expect(writers.map(\.bookIDs) == [[dune.id]])
}
