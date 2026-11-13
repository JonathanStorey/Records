import CloudKit
import Testing
@testable import Records

@Record
struct Label: Equatable {
    var name: String
}

@Record
struct Page {
    var title: String
    @Reference var labels: [Label]
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func labels(_ names: String...) -> [Label] {
    names.map { Label(name: $0) }
}

private func decodedLinks(_ records: [CKRecord]) throws -> [RecordLink] {
    try records.map { try decoder.decode(RecordLink.self, from: $0) }
}

/// A page that was saved with its links and read back with its labels.
private func savedPage(_ items: [Label]) throws -> (page: Page, links: [CKRecord]) {
    let page = Page(title: "Notes", labels: items)
    let links = encoder.links(for: page, in: .records)
    let decoded = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: links.shuffled(), targets: items.map { encoder.encode($0, in: .records) }
    )
    return (decoded, links)
}

// MARK: - Storage

@Test func toManyHoldsRecordsSortedByID() {
    let items = labels("a", "b", "c")
    var page = Page(title: "Notes", labels: items)
    #expect(page.labels == items)
    #expect(page._labels.ids == items.map(\.id))

    page._labels.values.removeFirst()
    #expect(page.labels == Array(items.dropFirst()))
}

@Test func toManyKeepsEachTargetOnce() {
    let item = Label(name: "a")
    let page = Page(title: "Notes", labels: [item, item])
    #expect(page.labels == [item])
}

@Test func settingRecordsKeepsTargetsThatWerentLoaded() throws {
    let items = labels("a", "b")
    let page = Page(title: "Notes", labels: items)
    let links = encoder.links(for: page, in: .records)
    var decoded = try decoder.decode(Page.self, from: encoder.encode(page, in: .records), links: links)
    #expect(decoded.labels.isEmpty)

    let added = Label(name: "c")
    decoded._labels.values.append(added)
    #expect(decoded._labels.ids == items.map(\.id) + [added.id])
    #expect(encoder.changes(for: decoded, from: links).saves.count == 1)
}

// MARK: - Links

@Test func newRecordWritesALinkPerTarget() throws {
    let items = labels("a", "b", "c")
    let page = Page(title: "Notes", labels: items)
    let links = try decodedLinks(encoder.links(for: page, in: .records))

    #expect(links.map(\.source) == Array(repeating: "Page.labels", count: 3))
    #expect(links.map(\.targetName) == items.map { Optional($0.id.uuidString) })
}

@Test func targetsSortByIDWhateverOrderTheyAreGiven() throws {
    let items = labels("a", "b", "c")
    let page = Page(title: "Notes", labels: [items[2], items[0], items[1]])
    #expect(page.labels == items)
    #expect(page.$labels.ids == items.map(\.id))
}

@Test func toManyLinksHaveOneIDPerTarget() throws {
    let items = labels("a", "b")
    let page = Page(title: "Notes", labels: items)
    let records = encoder.links(for: page, in: .records)
    #expect(Set(records.map(\.recordID)).count == 2)

    let id = RecordLink.id(source: "Page.labels", kind: .manyToMany, sourceName: page.id.uuidString, targetName: items[0].id.uuidString)
    #expect(records[0].recordID.recordName == id.uuidString)
}

@Test func loadedToManyReadsBackSortedByID() throws {
    let items = labels("a", "b", "c")
    let (page, links) = try savedPage(items)
    #expect(page.labels == items)
    #expect(encoder.changes(for: page, from: links).isEmpty)
}

@Test func addingWritesOneLink() throws {
    var (page, links) = try savedPage(labels("a", "b"))
    page._labels.values.append(Label(name: "c"))

    let changes = encoder.changes(for: page, from: links)
    #expect(changes.saves.count == 1)
    #expect(changes.deletes.isEmpty)
}

@Test func removingDeletesOneLink() throws {
    var (page, links) = try savedPage(labels("a", "b", "c"))
    page._labels.values.remove(at: 1)

    let changes = encoder.changes(for: page, from: links)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == [links[1].recordID])
}
