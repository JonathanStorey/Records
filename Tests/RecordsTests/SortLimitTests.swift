import Foundation
import Testing
@testable import Records

private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Gauges whose `steps` are all different, so any sort ending in `steps` has one right answer.
private func gauges() -> [Gauge] {
    let grades: [Grade?] = [nil, .one, .two, nil, .three, .one, nil, .two]
    return (0..<8).map { index in
        Gauge(
            id: UUID(), name: "Gauge \(index)", level: Double((index * 5) % 8) / 2, steps: (index * 3) % 8,
            limit: 4, checkedAt: base.addingTimeInterval(Double((index * 7) % 8)), isOn: index.isMultiple(of: 2),
            mood: index < 4 ? .calm : .energetic, rating: grades[index], nickname: nil
        )
    }
}

private func orderBy(_ sortBy: [SortDescriptor<Gauge>]) -> String? {
    PredicateTranslator(for: Gauge.self).orderBy(sortBy)
}

@Test func numbersAndDatesSortInSQL() {
    #expect(orderBy([]) == #""Gauge"."_name" ASC"#)
    #expect(orderBy([SortDescriptor(\.steps)]) == #""Gauge"."steps" ASC, "Gauge"."_name" ASC"#)
    #expect(orderBy([SortDescriptor(\.level, order: .reverse), SortDescriptor(\.checkedAt)])
        == #""Gauge"."level" DESC, "Gauge"."checkedAt" ASC, "Gauge"."_name" ASC"#)
}

@Test func optionalNumbersSortInSQL() {
    let translator = PredicateTranslator(for: Note.self)
    #expect(translator.orderBy([SortDescriptor(\Note.rating)]) == #""Note"."rating" ASC, "Note"."_name" ASC"#)
}

@MainActor
@Test func nilSortsFirstInSQLAsInSwift() throws {
    let context = try RecordContainer(for: [Note.self], url: nil).mainContext
    let ratings: [Int?] = [3, nil, 1, nil, 2]
    for (index, rating) in ratings.enumerated() {
        context.insert(Note(id: UUID(), title: "\(index)", isPinned: false, rating: rating, tags: [], created: base))
    }
    try context.save()
    let forward = try context.fetch(RecordDescriptor<Note>(sortBy: [SortDescriptor(\.rating)], fetchLimit: 5))
    #expect(forward.map(\.rating) == [nil, nil, 1, 2, 3])
    let reverse = try context.fetch(RecordDescriptor<Note>(sortBy: [SortDescriptor(\.rating, order: .reverse)], fetchLimit: 5))
    #expect(reverse.map(\.rating) == [3, 2, 1, nil, nil])
}

@Test func stringsSortInSwift() {
    #expect(orderBy([SortDescriptor(\.name)]) == nil)
    #expect(orderBy([SortDescriptor(\.nickname)]) == nil)
    #expect(orderBy([SortDescriptor(\.steps), SortDescriptor(\.name)]) == nil)
}

/// What `fetch` returns, worked out in Swift from every saved record.
private func expected(_ descriptor: RecordDescriptor<Gauge>, in records: [Gauge]) throws -> [UUID] {
    var result = try records.filter { try descriptor.predicate?.evaluate($0) ?? true }
    result.sort(using: descriptor.sortBy)
    let start = min(descriptor.fetchOffset ?? 0, result.count)
    let end = descriptor.fetchLimit.map { min(start + $0, result.count) } ?? result.count
    return result[start..<end].map(\.id)
}

@MainActor
@Test func sortingAndLimitingInSQLMatchesSwift() throws {
    let context = try RecordContainer(for: [Gauge.self], url: nil).mainContext
    for gauge in gauges() { context.insert(gauge) }
    try context.save()
    let saved = try context.fetch(RecordDescriptor<Gauge>())

    let descriptors: [RecordDescriptor<Gauge>] = [
        RecordDescriptor(sortBy: [SortDescriptor(\.steps)]),
        RecordDescriptor(sortBy: [SortDescriptor(\.steps, order: .reverse)], fetchLimit: 3),
        RecordDescriptor(sortBy: [SortDescriptor(\.steps)], fetchLimit: 3, fetchOffset: 2),
        RecordDescriptor(sortBy: [SortDescriptor(\.level), SortDescriptor(\.steps)], fetchLimit: 5),
        RecordDescriptor(sortBy: [SortDescriptor(\.checkedAt, order: .reverse), SortDescriptor(\.steps)], fetchOffset: 6),
        RecordDescriptor(
            predicate: #Predicate { $0.steps > 1 && $0.isOn },
            sortBy: [SortDescriptor(\.level, order: .reverse), SortDescriptor(\.steps)],
            fetchLimit: 2
        ),
        RecordDescriptor(predicate: #Predicate { !$0.isOn }, sortBy: [SortDescriptor(\.steps)], fetchOffset: 1),
        RecordDescriptor(sortBy: [SortDescriptor(\.steps)], fetchLimit: 0),
        RecordDescriptor(sortBy: [SortDescriptor(\.steps)], fetchOffset: 20),
    ]
    for (index, descriptor) in descriptors.enumerated() {
        let fetched = try context.fetch(descriptor).map(\.id)
        #expect(fetched == (try expected(descriptor, in: saved)), "descriptor \(index)")
        #expect(try context.fetchCount(descriptor) == fetched.count, "descriptor \(index)")
    }
}

@MainActor
@Test func aLimitWithoutASortReturnsThatManyRecords() throws {
    let context = try RecordContainer(for: [Gauge.self], url: nil).mainContext
    for gauge in gauges() { context.insert(gauge) }
    try context.save()
    #expect(try context.fetch(RecordDescriptor<Gauge>(fetchLimit: 3)).count == 3)
    #expect(try context.fetchCount(RecordDescriptor<Gauge>(fetchLimit: 3)) == 3)
    #expect(try context.fetchCount(RecordDescriptor<Gauge>(predicate: #Predicate { $0.isOn })) == 4)
}

@MainActor
@Test func stagedChangesStillCountWithALimit() throws {
    let context = try RecordContainer(for: [Gauge.self], url: nil).mainContext
    var records = gauges()
    for gauge in records { context.insert(gauge) }
    try context.save()

    // Stage a record that sorts first, and delete the one that sorted first.
    let first = try #require(records.min { $0.steps < $1.steps })
    context.delete(first)
    var newcomer = records[1]
    newcomer.id = UUID()
    newcomer.steps = -1
    context.insert(newcomer)
    records.removeAll { $0.id == first.id }
    records.append(newcomer)

    let descriptor = RecordDescriptor<Gauge>(sortBy: [SortDescriptor(\.steps)], fetchLimit: 2)
    let fetched = try context.fetch(descriptor)
    #expect(fetched.first?.id == newcomer.id)
    #expect(!fetched.contains { $0.id == first.id })
    #expect(try context.fetchCount(RecordDescriptor<Gauge>()) == 8)
}

@MainActor
@Test func linksLoadForTheRecordsInTheLimit() throws {
    let context = try RecordContainer(for: [Page.self, Novel.self], url: nil).mainContext
    let labels = (0..<5).map { Label(id: UUID(), name: "\($0)") }
    for index in 0..<5 {
        context.insert(Page(id: UUID(), title: "\(index)", labels: [labels[index]], pinnedIDs: []))
    }
    try context.save()
    let pages = try context.fetch(RecordDescriptor<Page>(fetchLimit: 2, fetchOffset: 1))
    #expect(pages.count == 2)
    for page in pages {
        let ids = page.referenceStates.first { $0.property == "labels" }?.ids ?? []
        #expect(ids == [labels[try #require(Int(page.title))].id])
    }
}
