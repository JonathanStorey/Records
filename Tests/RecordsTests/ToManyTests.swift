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
    @Reference(Label.self) var pinnedIDs: [UUID]
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
    let page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    let links = encoder.linksToSave(for: page, in: .records)
    let decoded = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: links.shuffled(), targets: items.map { encoder.encode($0, in: .records) }
    )
    return (decoded, links)
}

// MARK: - Storage

@Test func toManyHoldsRecordsInOrder() {
    let items = labels("a", "b", "c")
    var page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    #expect(page.labels == items)
    #expect(page._labels.ids == items.map(\.id))

    page.labels.removeFirst()
    #expect(page.labels == Array(items.dropFirst()))
}

@Test func toManyKeepsEachTargetOnce() {
    let item = Label(id: UUID(), name: "a")
    let page = Page(id: UUID(), title: "Notes", labels: [item, item], pinnedIDs: [])
    #expect(page.labels == [item])
}

@Test func settingRecordsKeepsTargetsThatWerentLoaded() throws {
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    var decoded = try decoder.decode(
        Page.self, from: encoder.encode(page, in: .records),
        links: encoder.linksToSave(for: page, in: .records)
    )
    #expect(decoded.labels.isEmpty)

    let added = Label(id: UUID(), name: "c")
    decoded.labels.append(added)
    #expect(decoded._labels.ids == items.map(\.id) + [added.id])
    #expect(encoder.linksToSave(for: decoded, in: .records).count == 1)
}

// MARK: - Links

@Test func newRecordWritesOrderedLinks() throws {
    let items = labels("a", "b", "c")
    let page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    let links = try decodedLinks(encoder.linksToSave(for: page, in: .records))

    #expect(links.map(\.relationship) == Array(repeating: "Page.labels:[Label]", count: 3))
    #expect(links.map(\.targetName) == items.map(\.id.uuidString))
    let orders = links.compactMap(\.order)
    #expect(orders.count == 3)
    #expect(zip(orders, orders.dropFirst()).allSatisfy { OrderKey.precedes($0, $1) })
}

@Test func toManyLinksHaveOneIDPerTarget() throws {
    let items = labels("a", "b")
    let page = Page(id: UUID(), title: "Notes", labels: items, pinnedIDs: [])
    let records = encoder.linksToSave(for: page, in: .records)
    #expect(Set(records.map(\.recordID)).count == 2)

    let factory = try RecordLink.manyToMany(from: page, property: "labels", to: Label.self, id: items[0].id, order: "x")
    #expect(records[0].recordID.recordName == factory.id.uuidString)
}

@Test func loadedToManyHasNoChanges() throws {
    let items = labels("a", "b", "c")
    let (page, _) = try savedPage(items)
    #expect(page.labels == items)
    #expect(encoder.linksToSave(for: page, in: .records).isEmpty)
    #expect(encoder.linkIDsToDelete(for: page, in: .records).isEmpty)
}

@Test func appendingWritesOneLinkAfterTheRest() throws {
    var (page, links) = try savedPage(labels("a", "b"))
    page.labels.append(Label(id: UUID(), name: "c"))

    let saves = try decodedLinks(encoder.linksToSave(for: page, in: .records))
    #expect(saves.count == 1)
    let last = try #require(try decodedLinks(links).compactMap(\.order).max(by: OrderKey.precedes))
    let added = try #require(saves.first?.order)
    #expect(OrderKey.precedes(last, added))
    #expect(encoder.linkIDsToDelete(for: page, in: .records).isEmpty)
}

@Test func removingDeletesOneLink() throws {
    var (page, links) = try savedPage(labels("a", "b", "c"))
    page.labels.remove(at: 1)

    #expect(encoder.linksToSave(for: page, in: .records).isEmpty)
    #expect(encoder.linkIDsToDelete(for: page, in: .records) == [links[1].recordID])
}

@Test func movingRewritesOneLink() throws {
    let items = labels("a", "b", "c")
    var (page, links) = try savedPage(items)
    page.labels = [items[2], items[0], items[1]]

    let saves = encoder.linksToSave(for: page, in: .records)
    #expect(saves.map(\.recordID) == [links[2].recordID])
    #expect(encoder.linkIDsToDelete(for: page, in: .records).isEmpty)

    let first = try #require(try decodedLinks(links)[0].order)
    let moved = try #require(try decodedLinks(saves)[0].order)
    #expect(OrderKey.precedes(moved, first))
}

@Test func markingSavedKeepsTheNewOrder() throws {
    let items = labels("a", "b", "c")
    var (page, _) = try savedPage(items)
    page.labels = [items[2], items[0], items[1]]
    page.markReferencesSaved()
    #expect(encoder.linksToSave(for: page, in: .records).isEmpty)
}

@Test func idFormWritesAndReadsLinks() throws {
    let ids = [UUID(), UUID()]
    let page = Page(id: UUID(), title: "Notes", labels: [], pinnedIDs: ids)
    let links = encoder.linksToSave(for: page, in: .records)
    #expect(try decodedLinks(links).map(\.relationship) == ["Page.pinnedIDs:[Label]", "Page.pinnedIDs:[Label]"])

    let decoded = try decoder.decode(Page.self, from: encoder.encode(page, in: .records), links: links.reversed())
    #expect(decoded.pinnedIDs == ids)
    #expect(decoded.labels.isEmpty)
}

// MARK: - Order keys

@Test func orderKeysStayBetweenTheirNeighbors() {
    var keys = [OrderKey.between(nil, nil)]
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
        let index = Int.random(in: 0...keys.count, using: &generator)
        let lower = index > 0 ? keys[index - 1] : nil
        let upper = index < keys.count ? keys[index] : nil
        let key = OrderKey.between(lower, upper)
        #expect(OrderKey.isValid(key))
        if let lower { #expect(OrderKey.precedes(lower, key)) }
        if let upper { #expect(OrderKey.precedes(key, upper)) }
        keys.insert(key, at: index)
    }
}

@Test func assignKeepsKeysThatStillSort() {
    #expect(OrderKey.assign(["a", "b", "c"]) == ["a", "b", "c"])

    let moved = OrderKey.assign(["c", "a", "b"])
    #expect(moved[1] == "a" && moved[2] == "b")
    #expect(OrderKey.precedes(moved[0], "a"))

    let inserted = OrderKey.assign(["a", nil, "b"])
    #expect(inserted[0] == "a" && inserted[2] == "b")
    #expect(OrderKey.precedes("a", inserted[1]) && OrderKey.precedes(inserted[1], "b"))
}

@Test func assignReplacesInvalidKeys() {
    let keys = OrderKey.assign(["a0", "", "b"])
    #expect(keys[2] == "b")
    #expect(keys.allSatisfy(OrderKey.isValid))
    #expect(OrderKey.precedes(keys[0], keys[1]) && OrderKey.precedes(keys[1], keys[2]))
}
