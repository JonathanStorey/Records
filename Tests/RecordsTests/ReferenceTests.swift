import CloudKit
import Testing
@testable import Records

@Record
struct Employee: Equatable {
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
    author: Person? = Person(name: "Ada"),
    editor: Person? = Person(name: "Grace")
) throws -> (article: Article, links: [CKRecord]) {
    let article = Article(title: "Notes", author: author, editor: editor)
    let links = encoder.links(for: article, in: .records)
    let targets = [author, editor].compactMap { $0.map { encoder.encode($0, in: .records) } }
    let decoded = try decoder.decode(
        Article.self, from: encoder.encode(article, in: .records), links: links, targets: targets
    )
    return (decoded, links)
}

// MARK: - Storage

@Test func referenceHoldsTheRecordAndItsID() {
    let ada = Person(name: "Ada")
    var article = Article(title: "Notes", author: ada, editor: nil)
    #expect(article.author == ada)
    #expect(article._author.id == ada.id)

    article._author.value = nil
    #expect(article.author == nil)
    #expect(article._author.id == nil)
}

@Test func recordCanReferToItsOwnType() throws {
    let boss = Employee(name: "Grace", manager: nil)
    let employee = Employee(name: "Ada", manager: boss)
    #expect(employee.manager == boss)

    let links = encoder.links(for: employee, in: .records)
    #expect(try links.map { try link($0).source } == ["Employee.manager"])
    #expect(signatures(of: employee) == ["Employee.manager:Employee"])

    let decoded = try decoder.decode(
        Employee.self, from: encoder.encode(employee, in: .records),
        links: links, targets: [encoder.encode(boss, in: .records)]
    )
    #expect(decoded.manager == boss)
    #expect(decoded == employee)
}

@Test func equalityComparesTargetsNotLoadedRecords() throws {
    let boss = Employee(name: "Grace", manager: nil)
    let employee = Employee(name: "Ada", manager: boss)
    let record = encoder.encode(employee, in: .records)
    let links = encoder.links(for: employee, in: .records)

    let withoutTarget = try decoder.decode(Employee.self, from: record, links: links)
    #expect(withoutTarget.manager == nil)
    #expect(withoutTarget._manager.id == boss.id)
    #expect(withoutTarget == employee)
}

// MARK: - Links

@Test func newRecordWritesALinkPerReference() throws {
    let ada = Person(name: "Ada"), grace = Person(name: "Grace")
    let article = Article(title: "Notes", author: ada, editor: grace)

    let links = encoder.links(for: article, in: .records)
    #expect(links.allSatisfy { $0.recordType == "RecordLink" && $0.recordID.zoneID == Zone.records.zoneID })

    let decoded = try links.map(link)
    #expect(decoded.map(\.source) == ["Article.author", "Article.editor"])
    #expect(signatures(of: article) == ["Article.author:Person", "Article.editor:Person"])
    #expect(decoded.map(\.sourceName) == [article.id.uuidString, article.id.uuidString])
    #expect(decoded.map(\.targetName) == [ada.id.uuidString, grace.id.uuidString])
    #expect(decoded.allSatisfy { $0.order == nil })
}

@Test func emptyReferencesWriteNoLinks() {
    let article = Article(title: "Notes", author: nil, editor: nil)
    #expect(encoder.links(for: article, in: .records).isEmpty)
}

@Test func loadedRecordHasTheSameLinks() throws {
    let (article, links) = try savedArticle()
    #expect(encoder.changes(for: article, from: links).isEmpty)
}

@Test func changingATargetOverwritesTheSameLink() throws {
    var (article, links) = try savedArticle()
    let newEditor = Person.ID()
    article._editor.value = Person(name: "Linus", id: newEditor)

    let changes = encoder.changes(for: article, from: links)
    #expect(changes.saves.map(\.recordID) == [links[1].recordID])
    #expect(try link(changes.saves[0]).targetName == newEditor.uuidString)
    #expect(changes.deletes.isEmpty)
}

@Test func clearingAReferenceDropsItsLink() throws {
    var (article, links) = try savedArticle()
    article._author.value = nil

    let changes = encoder.changes(for: article, from: links)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == [links[0].recordID])
}

// MARK: - Decoding with links

@Test func depthSetsHowManyLevelsHoldRecords() throws {
    let top = Employee(name: "Linus", manager: nil)
    let boss = Employee(name: "Grace", manager: top)
    let employee = Employee(name: "Ada", manager: boss)
    let links = [employee, boss].flatMap { encoder.links(for: $0, in: .records) }
    let records = [employee, boss, top].map { encoder.encode($0, in: .records) }

    let bare = try decoder.decode(Employee.self, from: records[0], links: links, targets: records, depth: 0)
    #expect(bare.manager == nil)
    #expect(bare.$manager.id == boss.id)

    let one = try decoder.decode(Employee.self, from: records[0], links: links, targets: records)
    #expect(one.manager?.name == "Grace")
    #expect(one.manager?.manager == nil)
    #expect(one.manager?.$manager.id == top.id)

    let two = try decoder.decode(Employee.self, from: records[0], links: links, targets: records, depth: 2)
    #expect(two.manager?.manager?.name == "Linus")
}

@Test func decodingFillsReferencesFromLinks() throws {
    let ada = Person(name: "Ada"), grace = Person(name: "Grace")
    let (article, _) = try savedArticle(author: ada, editor: grace)
    #expect(article.author == ada)
    #expect(article.editor == grace)
}

@Test func decodingWithoutTargetsFillsOnlyIDs() throws {
    let ada = Person(name: "Ada")
    let article = Article(title: "Notes", author: ada, editor: nil)
    let links = encoder.links(for: article, in: .records)
    let decoded = try decoder.decode(Article.self, from: encoder.encode(article, in: .records), links: links)
    #expect(decoded.author == nil)
    #expect(decoded._author.id == ada.id)
    #expect(encoder.changes(for: decoded, from: links).isEmpty)
}

@Test func decodingIgnoresOtherRecordsLinks() throws {
    let other = Article(title: "Other", author: Person(name: "Ada"), editor: Person(name: "Grace"))
    let article = Article(title: "Notes", author: nil, editor: nil)
    let decoded = try decoder.decode(
        Article.self, from: encoder.encode(article, in: .records),
        links: encoder.links(for: other, in: .records)
    )
    #expect(decoded._author.id == nil)
    #expect(decoded._editor.id == nil)
}

@Test func dollarNameReadsTheIDs() {
    let shelf = Shelf(name: "Fiction", bookIDs: [])
    let book = Book(title: "Dune", shelf: shelf)
    let songs = ["Intro", "Outro"].map { Song(title: $0, albumID: nil) }
    let release = Release(tracks: songs)

    #expect(book.$shelf.id == shelf.id)
    #expect(Book(title: "Emma", shelf: nil).$shelf.id == nil)
    #expect(release.$tracks.ids == songs.map(\.id))
}
