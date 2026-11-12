import CloudKit
import Testing
@testable import Records

@Record
struct Label: Equatable {
    var id: UUID
    var name: String
}

@Record
struct Page {
    var id: UUID
    var title: String
    @Reference var labels: [Label]
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func labels(_ names: String...) -> [Label] {
    names.map { Label(id: UUID(), name: $0) }
}

private func decodedLinks(_ records: [CKRecord]) throws -> [RecordLink] {
    try records.map { try decoder.decode(RecordLink.self, from: $0) }
}

/// A page that was saved with its links and read back with its labels.
private func savedPage(_ items: [Label]) throws -> (page: Page, links: [CKRecord]) {
    let page = Page(id: UUID(), title: "Notes", labels: items)
    let links = encoder.links(for: page, in: .records)
    let decoded = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: links.shuffled(), targets: items.map { encoder.encode($0, in: .records) }
    )
    return (decoded, links)
}

// MARK: - Storage

@Test func toManyHoldsRecordsInOrder() {
    let items = labels("a", "b", "c")
    var page = Page(id: UUID(), title: "Notes", labels: items)
    #expect(page.labels == items)
    #expect(page.$labels.ids == items.map(\.id))

    page.labels.removeFirst()
    #expect(page.labels == Array(items.dropFirst()))
}

@Test func toManyKeepsEachTargetOnce() {
    let item = Label(id: UUID(), name: "a")
    let page = Page(id: UUID(), title: "Notes", labels: [item, item])
    #expect(page.labels == [item])
}

@Test func settingRecordsKeepsTargetsThatWerentLoaded() throws {
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: items)
    let links = encoder.links(for: page, in: .records)
    var decoded = try decoder.decode(Page.self, from: encoder.encode(page, in: .records), links: links)
    #expect(decoded.labels.isEmpty)

    let added = Label(id: UUID(), name: "c")
    decoded.labels.append(added)
    #expect(decoded.$labels.ids == items.map(\.id) + [added.id])
    #expect(encoder.changes(for: decoded, from: links).saves.count == 1)
}

// MARK: - Links

@Test func newRecordWritesLinksInTheOrderGiven() throws {
    let items = labels("a", "b", "c")
    let page = Page(id: UUID(), title: "Notes", labels: items)
    let links = try decodedLinks(encoder.links(for: page, in: .records))

    #expect(links.map(\.source) == Array(repeating: "Page.labels", count: 3))
    #expect(links.map(\.targetName) == items.map { Optional($0.id.uuidString) })
    let dates = links.compactMap(\.added)
    #expect(dates.count == 3)
    #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func toManyLinksHaveOneIDPerTarget() throws {
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: items)
    let records = encoder.links(for: page, in: .records)
    #expect(Set(records.map(\.recordID)).count == 2)

    let id = RecordLink.id(source: "Page.labels", kind: .manyToMany, sourceName: page.id.uuidString, targetName: items[0].id.uuidString)
    #expect(records[0].recordID.recordName == id.uuidString)
}

@Test func loadedToManyKeepsTheOrderAdded() throws {
    let items = labels("a", "b", "c")
    let (page, links) = try savedPage(items)
    #expect(page.labels == items)
    #expect(encoder.changes(for: page, from: links).isEmpty)
}

@Test func appendingWritesOneLinkAfterTheRest() throws {
    var (page, links) = try savedPage(labels("a", "b"))
    page.labels.append(Label(id: UUID(), name: "c"))

    let changes = encoder.changes(for: page, from: links)
    let saves = try decodedLinks(changes.saves)
    #expect(saves.count == 1)
    let last = try #require(try decodedLinks(links).compactMap(\.added).max())
    let added = try #require(saves.first?.added)
    #expect(last < added)
    #expect(changes.deletes.isEmpty)
}

@Test func removingDeletesOneLink() throws {
    var (page, links) = try savedPage(labels("a", "b", "c"))
    page.labels.remove(at: 1)

    let changes = encoder.changes(for: page, from: links)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == [links[1].recordID])
}

@Test func removingByIDWorksWhenNotLoaded() throws {
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: items)
    let links = encoder.links(for: page, in: .records)
    var decoded = try decoder.decode(Page.self, from: encoder.encode(page, in: .records), links: links)
    decoded.$labels.remove(id: items[0].id)

    #expect(decoded.$labels.ids == [items[1].id])
    #expect(encoder.changes(for: decoded, from: links).deletes == [links[0].recordID])
}

@Test func reorderingInMemoryIsNotSaved() throws {
    let items = labels("a", "b", "c")
    var (page, links) = try savedPage(items)
    page.labels = [items[2], items[0], items[1]]
    #expect(encoder.changes(for: page, from: links).isEmpty)

    let reread = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: encoder.links(for: page, in: .records, existing: links), targets: items.map { encoder.encode($0, in: .records) }
    )
    #expect(reread.labels == items)
}

@Test func removingAndAddingBackMovesToTheEnd() throws {
    let items = labels("a", "b", "c")
    var (page, links) = try savedPage(items)
    page.labels.removeFirst()
    links = encoder.links(for: page, in: .records, existing: links)
    page.labels.append(items[0])
    links = encoder.links(for: page, in: .records, existing: links)

    let reread = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: links.shuffled(), targets: items.map { encoder.encode($0, in: .records) }
    )
    #expect(reread.labels == [items[1], items[2], items[0]])
}

@Test func tiesBreakByID() throws {
    let page = Page(id: UUID(), title: "Notes", labels: [])
    let ids = (0..<5).map { _ in UUID() }
    let same = Date(timeIntervalSinceReferenceDate: 1_000)
    let links = ids.map { id in
        RecordLink(
            id: UUID(), source: "Page.labels", sourceName: page.id.uuidString,
            targetName: id.uuidString, added: same
        )
    }
    var graph = RecordGraph()
    for link in links.shuffled() { graph.add(link) }
    var loaded = page
    try graph.load(&loaded, depth: 0)
    #expect(loaded.$labels.ids == ids.sorted { $0.uuidString < $1.uuidString })
}
