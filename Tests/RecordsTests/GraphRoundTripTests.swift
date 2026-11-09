import CloudKit
import Testing
@testable import Records

// A small project tracker that uses every reference form:
//
// - to-one record:  Card.assignee, Board.owner, Member.mentor (its own type)
// - to-one ID:      Card.featuredBadgeID, Board.parentID (its own type)
// - to-many record: Card.badges, Board.cards, Board.subboards (its own type)
// - to-many ID:     Card.blockedByIDs (its own type), Member.peerIDs (its own type)

@Record
struct Member: Equatable {
    var id: UUID
    var name: String
    @Reference var mentor: Member?
    @Reference(Member.self) var peerIDs: [UUID]
}

@Record
struct Badge: Equatable {
    var id: UUID
    var title: String
}

@Record
struct Card: Equatable {
    var id: UUID
    var title: String
    var isDone: Bool
    var due: Date?
    var checklist: [String]
    @Reference var assignee: Member?
    @Reference var badges: [Badge]
    @Reference(Card.self) var blockedByIDs: [UUID]
    @Reference(Badge.self) var featuredBadgeID: UUID?
}

@Record
struct Board: Equatable {
    var id: UUID
    var name: String
    @Reference var owner: Member?
    @Reference var cards: [Card]
    @Reference(Board.self) var parentID: UUID?
    @Reference var subboards: [Board]
}

// Macro shapes: public types, generic types, backticked names, `Array<T>`, and the
// module-qualified attribute.

@Record
public struct Owner: Equatable {
    public var id: UUID
    @Reference public var boss: Owner?
    @Reference(Owner.self) public var reportIDs: [UUID]
}

@Record("Bin")
struct Bin<Value: CKRecordValueProtocol & Equatable>: Equatable {
    var id: UUID
    var value: Value
    @Reference var owner: Member?
}

@Record
struct Keyword: Equatable {
    var id: UUID
    @Reference var `default`: Badge?
    @Records.Reference var badges: Array<Badge>
}

/// The CKRecords the encoder produced, by record ID. Saving writes the record and its link
/// saves, removes its link deletes, and marks its references saved. Loading decodes a record
/// from them with every link and record as context.
private struct SavedRecords {
    var records: [CKRecord.ID: CKRecord] = [:]
    let zone: Zone = .records

    var links: [CKRecord] { records.values.filter { $0.recordType == "RecordLink" } }

    mutating func save<R: Record>(_ record: inout R) {
        let encoder = CKRecordEncoder()
        let ckRecord = encoder.encode(record, in: zone)
        records[ckRecord.recordID] = ckRecord
        for link in encoder.linksToSave(for: record, in: zone) {
            records[link.recordID] = link
        }
        for id in encoder.linkIDsToDelete(for: record, in: zone) {
            records[id] = nil
        }
        record.markReferencesSaved()
    }

    func load<R: Record>(_ type: R.Type, _ id: UUID, depth: Int = 1) throws -> R {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
        let record = try #require(records[recordID])
        return try CKRecordDecoder().decode(type, from: record, links: links, targets: Array(records.values), depth: depth)
    }
}

private func hasNoChanges(_ record: some Record) -> Bool {
    let encoder = CKRecordEncoder()
    return encoder.linksToSave(for: record, in: .records).isEmpty
        && encoder.linkIDsToDelete(for: record, in: .records).isEmpty
}

/// A saved graph with a mentor cycle, a card shared by two boards, and a nested board.
private struct Graph {
    var saved = SavedRecords()
    var ada = Member(id: UUID(), name: "Ada", mentor: nil, peerIDs: [])
    var grace = Member(id: UUID(), name: "Grace", mentor: nil, peerIDs: [])
    let urgent = Badge(id: UUID(), title: "Urgent")
    let bug = Badge(id: UUID(), title: "Bug")
    let ux = Badge(id: UUID(), title: "UX")
    var first: Card
    var second: Card
    var root: Board
    var child: Board

    init() {
        ada.mentor = grace
        ada.peerIDs = [grace.id]
        grace.mentor = ada // a cycle: each mentors the other
        second = Card(
            id: UUID(), title: "Write tests", isDone: true, due: nil, checklist: [],
            assignee: grace, badges: [], blockedByIDs: [], featuredBadgeID: nil
        )
        first = Card(
            id: UUID(), title: "Ship", isDone: false, due: Date(timeIntervalSince1970: 1_000),
            checklist: ["build", "tag"], assignee: ada, badges: [bug, urgent],
            blockedByIDs: [second.id], featuredBadgeID: ux.id
        )
        child = Board(id: UUID(), name: "Later", owner: grace, cards: [second], parentID: nil, subboards: [])
        root = Board(id: UUID(), name: "Roadmap", owner: ada, cards: [first, second], parentID: nil, subboards: [child])
        child.parentID = root.id

        var badges = [urgent, bug, ux]
        for index in badges.indices { saved.save(&badges[index]) }
        saved.save(&ada)
        saved.save(&grace)
        saved.save(&first)
        saved.save(&second)
        saved.save(&root)
        saved.save(&child)
    }
}

// MARK: - Round trip

@Test func graphRoundTripsThroughCKRecords() throws {
    let graph = Graph()
    let saved = graph.saved

    // 9 records, plus links: Ada 2, Grace 1, first card 5, second card 1, root 4, child 3.
    #expect(saved.records.count == 9 + 16)
    #expect(saved.links.count == 16)

    let ada = try saved.load(Member.self, graph.ada.id)
    let first = try saved.load(Card.self, graph.first.id)
    let root = try saved.load(Board.self, graph.root.id)
    let child = try saved.load(Board.self, graph.child.id)

    // Fields and references compare equal, every record starts out unchanged.
    #expect(ada == graph.ada)
    #expect(first == graph.first)
    #expect(root == graph.root)
    #expect(child == graph.child)
    #expect([hasNoChanges(ada), hasNoChanges(first), hasNoChanges(root), hasNoChanges(child)] == [true, true, true, true])

    // Every form reads back.
    #expect(first.assignee?.name == "Ada")
    #expect(first.badges.map(\.title) == ["Bug", "Urgent"])
    #expect(first.blockedByIDs == [graph.second.id])
    #expect(first.featuredBadgeID == graph.ux.id)
    #expect(first.due == Date(timeIntervalSince1970: 1_000))
    #expect(first.checklist == ["build", "tag"])
    #expect(root.cards.map(\.title) == ["Ship", "Write tests"])
    #expect(child.parentID == graph.root.id)
    #expect(child.cards.map(\.id) == [graph.second.id])
}

@Test func loadingFillsOneLevelDeep() throws {
    let graph = Graph()
    let root = try graph.saved.load(Board.self, graph.root.id)

    // The root's own references are loaded.
    let ship = try #require(root.cards.first)
    let later = try #require(root.subboards.first)
    #expect(root.owner?.name == "Ada")
    #expect(later.name == "Later")

    // Their references hold IDs from the links, but not records.
    #expect(ship._assignee.id == graph.ada.id)
    #expect(ship.assignee == nil)
    #expect(ship._badges.ids == [graph.bug.id, graph.urgent.id])
    #expect(ship.badges.isEmpty)
    #expect(ship.blockedByIDs == [graph.second.id]) // ID forms need no loading
    #expect(later._cards.ids == [graph.second.id])
    #expect(later.parentID == graph.root.id)

    // A nested record still equals the saved one, because equality compares targets.
    #expect(ship == graph.first)
}

@Test func cyclesLoadOneLevelDeep() throws {
    let graph = Graph()
    let ada = try graph.saved.load(Member.self, graph.ada.id)
    let mentor = try #require(ada.mentor)
    #expect(mentor.name == "Grace")
    #expect(mentor._mentor.id == graph.ada.id)
    #expect(mentor.mentor == nil)
    #expect(ada.peerIDs == [graph.grace.id])
}

@Test func deeperLoadsFollowCyclesUntilTheDepthRunsOut() throws {
    let graph = Graph()
    let ada = try graph.saved.load(Member.self, graph.ada.id, depth: 4)

    // Ada → Grace → Ada → Grace, then only Grace's mentor's ID.
    let last = try #require(ada.mentor?.mentor?.mentor?.mentor)
    #expect(last.name == "Grace")
    #expect(last.mentor == nil)
    #expect(last._mentor.id == graph.ada.id)
    #expect(hasNoChanges(ada))
}

// MARK: - Edit and round trip again

@Test func editsRoundTrip() throws {
    var graph = Graph()
    var first = try graph.saved.load(Card.self, graph.first.id)
    var root = try graph.saved.load(Board.self, graph.root.id)
    var child = try graph.saved.load(Board.self, graph.child.id)
    var ada = try graph.saved.load(Member.self, graph.ada.id)

    first.badges = [graph.urgent, graph.ux] // remove bug, keep urgent, add ux
    first.assignee = graph.grace            // retarget
    first.featuredBadgeID = nil             // clear
    first.blockedByIDs = []                 // remove the only one
    first.isDone = true
    root.cards.reverse()                    // move
    child.parentID = nil                    // clear a self-reference
    child.subboards = [root]                // add a self-reference, making a cycle of boards
    ada.mentor = nil                        // break the mentor cycle

    graph.saved.save(&first)
    graph.saved.save(&root)
    graph.saved.save(&child)
    graph.saved.save(&ada)
    #expect([hasNoChanges(first), hasNoChanges(root), hasNoChanges(child), hasNoChanges(ada)] == [true, true, true, true])

    let firstAgain = try graph.saved.load(Card.self, graph.first.id)
    let rootAgain = try graph.saved.load(Board.self, graph.root.id)
    let childAgain = try graph.saved.load(Board.self, graph.child.id)
    let adaAgain = try graph.saved.load(Member.self, graph.ada.id)

    #expect(firstAgain == first)
    #expect(firstAgain.isDone)
    #expect(firstAgain.badges.map(\.title) == ["Urgent", "UX"])
    #expect(firstAgain.assignee?.name == "Grace")
    #expect(firstAgain.featuredBadgeID == nil)
    #expect(firstAgain.blockedByIDs.isEmpty)
    #expect(rootAgain.cards.map(\.title) == ["Write tests", "Ship"])
    #expect(childAgain.parentID == nil)
    #expect(childAgain.subboards.map(\.name) == ["Roadmap"])
    #expect(adaAgain.mentor == nil)
    #expect(adaAgain.peerIDs == [graph.grace.id])

    // Card: -bug -blockedBy -featured +ux, with the assignee overwritten in place. Root: the
    // move rewrites a link without adding one. Child: -parent +subboard. Ada: -mentor.
    #expect(graph.saved.links.count == 16 - 3 + 1 + 0 - 1)
}

@Test func revertingAnEditWritesNothing() throws {
    let graph = Graph()
    var first = try graph.saved.load(Card.self, graph.first.id)
    var root = try graph.saved.load(Board.self, graph.root.id)

    first.assignee = graph.grace
    first.assignee = graph.ada
    first.badges = []
    first.badges = [graph.bug, graph.urgent]
    root.cards.reverse()
    root.cards.reverse()

    #expect(hasNoChanges(first))
    #expect(hasNoChanges(root))
}

@Test func nestedEditsAreSavedOnlyWithTheirOwnRecord() throws {
    var graph = Graph()
    var root = try graph.saved.load(Board.self, graph.root.id)

    root.owner?.name = "Augusta"
    #expect(hasNoChanges(root)) // same target, so no link to write
    graph.saved.save(&root)
    #expect(try graph.saved.load(Member.self, graph.ada.id).name == "Ada")

    var owner = try #require(root.owner)
    graph.saved.save(&owner)
    #expect(try graph.saved.load(Member.self, graph.ada.id).name == "Augusta")
}

// MARK: - Odd links

@Test func linkForAnUnknownPropertyIsIgnored() throws {
    var graph = Graph()
    let stale = try RecordLink.manyToOne(from: graph.first, property: "reviewer", to: Member.self, id: graph.ada.id)
    let record = CKRecordEncoder().encode(stale, in: .records)
    graph.saved.records[record.recordID] = record

    let first = try graph.saved.load(Card.self, graph.first.id)
    #expect(first == graph.first)
    #expect(hasNoChanges(first))
}

@Test func targetOfTheWrongTypeIsNotDecoded() throws {
    let graph = Graph()
    let card = graph.first
    let impostor = CKRecord(
        recordType: "Badge",
        recordID: CKRecord.ID(recordName: graph.ada.id.uuidString, zoneID: Zone.records.zoneID)
    )
    impostor["title"] = "Not a member"

    let decoded = try CKRecordDecoder().decode(
        Card.self, from: CKRecordEncoder().encode(card, in: .records),
        links: graph.saved.links, targets: [impostor]
    )
    #expect(decoded._assignee.id == graph.ada.id)
    #expect(decoded.assignee == nil)
}

@Test func toManyLinkWithoutAnOrderKeyGetsOneOnTheNextSave() throws {
    var graph = Graph()
    var link = try RecordLink.manyToMany(
        from: graph.first, property: "badges", to: Badge.self, id: graph.ux.id, order: "x"
    )
    link.order = nil
    let record = CKRecordEncoder().encode(link, in: .records)
    graph.saved.records[record.recordID] = record

    var first = try graph.saved.load(Card.self, graph.first.id)
    #expect(first.badges.map(\.title) == ["UX", "Bug", "Urgent"]) // no key sorts first

    let saves = CKRecordEncoder().linksToSave(for: first, in: .records)
    #expect(saves.map(\.recordID) == [record.recordID])
    #expect(saves.first?["order"] is String)

    graph.saved.save(&first)
    #expect(try hasNoChanges(graph.saved.load(Card.self, graph.first.id)))
}

// MARK: - Macro shapes

@Test func publicGenericAndEscapedRecordsRoundTrip() throws {
    var saved = SavedRecords()
    var member = Member(id: UUID(), name: "Ada", mentor: nil, peerIDs: [])
    var badge = Badge(id: UUID(), title: "Gold")
    var boss = Owner(id: UUID(), boss: nil, reportIDs: [])
    var owner = Owner(id: UUID(), boss: boss, reportIDs: [UUID()])
    var bin = Bin(id: UUID(), value: 42, owner: member)
    var keyword = Keyword(id: UUID(), default: badge, badges: [badge])
    saved.save(&member)
    saved.save(&badge)
    saved.save(&boss)
    saved.save(&owner)
    saved.save(&bin)
    saved.save(&keyword)

    let ownerAgain = try saved.load(Owner.self, owner.id)
    #expect(ownerAgain == owner)
    #expect(ownerAgain.boss == boss)

    let binAgain = try saved.load(Bin<Int>.self, bin.id)
    #expect(binAgain == bin)
    #expect(binAgain.owner?.name == "Ada")
    let binLink = try #require(saved.links.first { ($0["sourceName"] as? String) == bin.id.uuidString })
    #expect(binLink["relationship"] as? String == "Bin.owner:Member")

    let keywordAgain = try saved.load(Keyword.self, keyword.id)
    #expect(keywordAgain.default == badge)
    #expect(keywordAgain.badges == [badge])
}
