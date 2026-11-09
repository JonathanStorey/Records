import CloudKit
import Testing
@testable import Records

// Records decoded from an incomplete set of CKRecords: links that haven't arrived, links whose
// target hasn't arrived, links that arrive late, and links this build can't read. Uses the
// Member, Badge, and Card records from GraphRoundTripTests.

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private struct Fixture {
    let ada = Member(id: UUID(), name: "Ada", mentor: nil, peerIDs: [])
    let grace = Member(id: UUID(), name: "Grace", mentor: nil, peerIDs: [])
    let a = Badge(id: UUID(), title: "A")
    let b = Badge(id: UUID(), title: "B")
    let c = Badge(id: UUID(), title: "C")
    let card: Card
    /// The card's links, by target: the assignee's, then one per badge.
    let links: [UUID: CKRecord]

    init() {
        let card = Card(
            id: UUID(), title: "Ship", isDone: false, due: nil, checklist: [],
            assignee: ada, badges: [a, b, c], blockedByIDs: [], featuredBadgeID: nil
        )
        self.card = card
        var links: [UUID: CKRecord] = [:]
        for link in encoder.linksToSave(for: card, in: .records) {
            links[UUID(uuidString: link["targetName"] as! String)!] = link
        }
        self.links = links
    }

    var cardRecord: CKRecord { encoder.encode(card, in: .records) }
    var targets: [CKRecord] { [ada, grace].map { encoder.encode($0, in: .records) } + [a, b, c].map { encoder.encode($0, in: .records) } }

    /// The card, decoded from the links for `present` only.
    func decode(withLinksTo present: [UUID], targets: [CKRecord]? = nil) throws -> Card {
        try decoder.decode(
            Card.self, from: cardRecord,
            links: present.compactMap { links[$0] }, targets: targets ?? self.targets
        )
    }
}

private func deletes(_ card: Card) -> [CKRecord.ID] {
    encoder.linkIDsToDelete(for: card, in: .records)
}

private func saves(_ card: Card) -> [CKRecord.ID] {
    encoder.linksToSave(for: card, in: .records).map(\.recordID)
}

// MARK: - Missing links

@Test func missingLinksDecodeAsEmptyReferences() throws {
    let fixture = Fixture()
    let card = try fixture.decode(withLinksTo: [])
    #expect(card.assignee == nil)
    #expect(card._assignee.id == nil)
    #expect(card.badges.isEmpty)
    #expect(saves(card).isEmpty && deletes(card).isEmpty)
}

@Test func unseenLinksAreNeverDeleted() throws {
    let fixture = Fixture()
    var card = try fixture.decode(withLinksTo: [fixture.a.id, fixture.c.id]) // assignee and b missing
    #expect(card.badges.map(\.title) == ["A", "C"])

    card.assignee = nil
    card.badges = [fixture.c]
    card.badges = []

    // Only the links the card was loaded with can be deleted.
    #expect(Set(deletes(card)) == [fixture.links[fixture.a.id]!.recordID, fixture.links[fixture.c.id]!.recordID])
}

@Test func settingAToOneWhoseLinkIsMissingOverwritesThatLink() throws {
    let fixture = Fixture()
    var card = try fixture.decode(withLinksTo: [])
    card.assignee = fixture.grace

    // To-one links don't depend on the target, so this is the same record as the unseen link.
    #expect(saves(card) == [fixture.links[fixture.ada.id]!.recordID])
    #expect(deletes(card).isEmpty)
}

// MARK: - Missing targets

@Test func linkWithoutItsTargetKeepsTheID() throws {
    let fixture = Fixture()
    let card = try fixture.decode(withLinksTo: [fixture.ada.id, fixture.a.id, fixture.b.id], targets: [])
    #expect(card.assignee == nil)
    #expect(card._assignee.id == fixture.ada.id)
    #expect(card.badges.isEmpty)
    #expect(card._badges.ids == [fixture.a.id, fixture.b.id])
    #expect(saves(card).isEmpty && deletes(card).isEmpty)
}

// MARK: - Late links

@Test func lateLinksFillReferencesOnTheNextDecode() throws {
    let fixture = Fixture()
    let early = try fixture.decode(withLinksTo: [fixture.a.id])
    #expect(early.assignee == nil)
    #expect(early.badges.map(\.title) == ["A"])

    let late = try fixture.decode(withLinksTo: [fixture.ada.id, fixture.a.id, fixture.b.id, fixture.c.id])
    #expect(late.assignee == fixture.ada)
    #expect(late.badges.map(\.title) == ["A", "B", "C"])
    #expect(late == fixture.card)
}

@Test func partialToManyKeepsOrderAndLeavesMissingLinksAlone() throws {
    let fixture = Fixture()
    var card = try fixture.decode(withLinksTo: [fixture.a.id, fixture.c.id]) // b missing
    card.badges = [fixture.c, fixture.a]

    // Moving C rewrites only C's link. B's link is untouched.
    let moved = encoder.linksToSave(for: card, in: .records)
    #expect(moved.map(\.recordID) == [fixture.links[fixture.c.id]!.recordID])
    #expect(deletes(card).isEmpty)

    // When B arrives, it sorts by its own key among the others.
    let bLink = try #require(fixture.links[fixture.b.id])
    let all = try decoder.decode(
        Card.self, from: fixture.cardRecord,
        links: moved + [fixture.links[fixture.a.id]!, bLink], targets: fixture.targets
    )
    #expect(all.badges.map(\.title) == ["C", "A", "B"])
}

// MARK: - Links this build can't read

/// A link record for the fixture's card with the given fields.
private func rawLink(
    source: UUID, relationship: Any, target: String, version: Int64 = RecordLink.currentVersion, order: String? = "x"
) -> CKRecord {
    let record = CKRecord(
        recordType: "RecordLink",
        recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Zone.records.zoneID)
    )
    record["relationship"] = relationship as? CKRecordValue
    record["sourceName"] = source.uuidString
    record["targetName"] = target
    record["deleteSelf"] = false
    record["order"] = order
    record["version"] = version
    return record
}

@Test func unreadableLinksAreSkipped() throws {
    let fixture = Fixture()
    let source = fixture.card.id
    let stranger = UUID()
    let unreadable = [
        rawLink(source: source, relationship: 5, target: stranger.uuidString),                       // wrong field type
        rawLink(source: source, relationship: "Card.badges:[Badge]", target: "not-a-uuid"),           // bad target ID
        rawLink(source: source, relationship: "garbage", target: stranger.uuidString),                // bad signature
        rawLink(source: source, relationship: "Card.badges:[Badge]", target: stranger.uuidString, version: RecordLink.currentVersion + 1), // newer version
    ]
    let badName = CKRecord(recordType: "RecordLink", recordID: CKRecord.ID(recordName: "link-1", zoneID: Zone.records.zoneID))

    let card = try decoder.decode(
        Card.self, from: fixture.cardRecord,
        links: unreadable + [badName] + Array(fixture.links.values), targets: fixture.targets
    )
    #expect(card == fixture.card)
    #expect(card.badges.map(\.title) == ["A", "B", "C"])
    #expect(!card._badges.ids.contains(stranger))
    #expect(saves(card).isEmpty && deletes(card).isEmpty)
}
