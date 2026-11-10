import CloudKit
import Testing
@testable import Records

@Record
struct Employee: Equatable {
    var id: UUID
    var name: String
    @Reference var manager: Employee?
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func link(_ record: CKRecord) throws -> RecordLink {
    try decoder.decode(RecordLink.self, from: record)
}

/// An article that was saved with its links, then read back.
private func savedArticle(
    author: Person? = Person(id: UUID(), name: "Ada"),
    editorID: UUID? = UUID()
) throws -> (article: Article, links: [CKRecord]) {
    let article = Article(id: UUID(), title: "Notes", author: author, editorID: editorID)
    let links = encoder.links(for: article, in: .records)
    let targets = [author].compactMap { $0.map { encoder.encode($0, in: .records) } }
    let decoded = try decoder.decode(
        Article.self, from: encoder.encode(article, in: .records), links: links, targets: targets
    )
    return (decoded, links)
}

// MARK: - Storage

@Test func referenceHoldsTheRecordAndItsID() {
    let ada = Person(id: UUID(), name: "Ada")
    var article = Article(id: UUID(), title: "Notes", author: ada, editorID: nil)
    #expect(article.author == ada)
    #expect(article._author.id == ada.id)

    article.author = nil
    #expect(article.author == nil)
    #expect(article._author.id == nil)
}

@Test func recordCanReferToItsOwnType() throws {
    let boss = Employee(id: UUID(), name: "Grace", manager: nil)
    let employee = Employee(id: UUID(), name: "Ada", manager: boss)
    #expect(employee.manager == boss)

    let links = encoder.links(for: employee, in: .records)
    #expect(try links.map { try link($0).relationship } == ["Employee.manager:Employee"])

    let decoded = try decoder.decode(
        Employee.self, from: encoder.encode(employee, in: .records),
        links: links, targets: [encoder.encode(boss, in: .records)]
    )
    #expect(decoded.manager == boss)
    #expect(decoded == employee)
}

@Test func equalityComparesTargetsNotLoadedRecords() throws {
    let boss = Employee(id: UUID(), name: "Grace", manager: nil)
    let employee = Employee(id: UUID(), name: "Ada", manager: boss)
    let record = encoder.encode(employee, in: .records)
    let links = encoder.links(for: employee, in: .records)

    let withoutTarget = try decoder.decode(Employee.self, from: record, links: links)
    #expect(withoutTarget.manager == nil)
    #expect(withoutTarget._manager.id == boss.id)
    #expect(withoutTarget == employee)
}

// MARK: - Links

@Test func newRecordWritesALinkPerReference() throws {
    let ada = Person(id: UUID(), name: "Ada"), editorID = UUID()
    let article = Article(id: UUID(), title: "Notes", author: ada, editorID: editorID)

    let links = encoder.links(for: article, in: .records)
    #expect(links.allSatisfy { $0.recordType == "RecordLink" && $0.recordID.zoneID == Zone.records.zoneID })

    let decoded = try links.map(link)
    #expect(decoded.map(\.relationship) == ["Article.author:Person", "Article.editorID:Person"])
    #expect(decoded.map(\.sourceName) == [article.id.uuidString, article.id.uuidString])
    #expect(decoded.map(\.targetName) == [ada.id.uuidString, editorID.uuidString])
    #expect(decoded.allSatisfy { $0.order == nil })
}

@Test func referenceLinkMatchesTheFactory() throws {
    let ada = Person(id: UUID(), name: "Ada")
    let article = Article(id: UUID(), title: "Notes", author: ada, editorID: nil)
    let written = try link(#require(encoder.links(for: article, in: .records).first))
    let built = try RecordLink.manyToOne(from: article, property: "author", to: Person.self, id: ada.id)
    #expect(written == built)
}

@Test func emptyReferencesWriteNoLinks() {
    let article = Article(id: UUID(), title: "Notes", author: nil, editorID: nil)
    #expect(encoder.links(for: article, in: .records).isEmpty)
}

@Test func loadedRecordHasTheSameLinks() throws {
    let (article, links) = try savedArticle()
    #expect(encoder.changes(for: article, from: links).isEmpty)
}

@Test func changingATargetOverwritesTheSameLink() throws {
    var (article, links) = try savedArticle()
    let newEditor = UUID()
    article.editorID = newEditor

    let changes = encoder.changes(for: article, from: links)
    #expect(changes.saves.map(\.recordID) == [links[1].recordID])
    #expect(try link(changes.saves[0]).targetName == newEditor.uuidString)
    #expect(changes.deletes.isEmpty)
}

@Test func clearingAReferenceDropsItsLink() throws {
    var (article, links) = try savedArticle()
    article.author = nil

    let changes = encoder.changes(for: article, from: links)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == [links[0].recordID])
}

// MARK: - Decoding with links

@Test func depthSetsHowManyLevelsHoldRecords() throws {
    let top = Employee(id: UUID(), name: "Linus", manager: nil)
    let boss = Employee(id: UUID(), name: "Grace", manager: top)
    let employee = Employee(id: UUID(), name: "Ada", manager: boss)
    let links = [employee, boss].flatMap { encoder.links(for: $0, in: .records) }
    let records = [employee, boss, top].map { encoder.encode($0, in: .records) }

    let bare = try decoder.decode(Employee.self, from: records[0], links: links, targets: records, depth: 0)
    #expect(bare.manager == nil)
    #expect(bare.$manager == boss.id)

    let one = try decoder.decode(Employee.self, from: records[0], links: links, targets: records)
    #expect(one.manager?.name == "Grace")
    #expect(one.manager?.manager == nil)
    #expect(one.manager?.$manager == top.id)

    let two = try decoder.decode(Employee.self, from: records[0], links: links, targets: records, depth: 2)
    #expect(two.manager?.manager?.name == "Linus")
}

@Test func decodingFillsReferencesFromLinks() throws {
    let ada = Person(id: UUID(), name: "Ada"), editorID = UUID()
    let (article, _) = try savedArticle(author: ada, editorID: editorID)
    #expect(article.author == ada)
    #expect(article.editorID == editorID)
}

@Test func decodingWithoutTargetsFillsOnlyIDs() throws {
    let ada = Person(id: UUID(), name: "Ada")
    let article = Article(id: UUID(), title: "Notes", author: ada, editorID: nil)
    let links = encoder.links(for: article, in: .records)
    let decoded = try decoder.decode(Article.self, from: encoder.encode(article, in: .records), links: links)
    #expect(decoded.author == nil)
    #expect(decoded._author.id == ada.id)
    #expect(encoder.changes(for: decoded, from: links).isEmpty)
}

@Test func decodingIgnoresOtherRecordsLinks() throws {
    let other = Article(id: UUID(), title: "Other", author: Person(id: UUID(), name: "Ada"), editorID: UUID())
    let article = Article(id: UUID(), title: "Notes", author: nil, editorID: nil)
    let decoded = try decoder.decode(
        Article.self, from: encoder.encode(article, in: .records),
        links: encoder.links(for: other, in: .records)
    )
    #expect(decoded._author.id == nil)
    #expect(decoded.editorID == nil)
}
