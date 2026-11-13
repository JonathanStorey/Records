import CloudKit
import Testing
@testable import Records

// Two-way many-to-many: a post orders its topics, and each topic lists its posts.

@Record
struct Post: Equatable {
    var title: String
    @Reference var topics: [Topic]
}

@Record
struct Topic: Equatable {
    var name: String
    @Reference(from: \Post.topics) var postIDs: [Post.ID]
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func link(_ record: CKRecord) throws -> RecordLink {
    try decoder.decode(RecordLink.self, from: record)
}

private struct Fixture {
    let swift = Topic(name: "Swift", postIDs: [])
    let ios = Topic(name: "iOS", postIDs: [])
    let first: Post
    let second: Post

    init() {
        first = Post(title: "Macros", topics: [swift, ios])
        second = Post(title: "Testing", topics: [swift])
    }

    var links: [CKRecord] {
        encoder.links(for: first, in: .records) + encoder.links(for: second, in: .records)
    }

    func record(_ topic: Topic) -> CKRecord { encoder.encode(topic, in: .records) }
}

@Test func ownerWritesManyToManyLinks() throws {
    let fixture = Fixture()
    let links = try fixture.links.map(link)

    #expect(links.count == 3)
    #expect(links.allSatisfy { $0.source == "Post.topics" })
    #expect(signatures(of: fixture.first) == ["Post.topics:[Topic] <-> Topic.postIDs:[Post]"])
    #expect(Relationship(fixture.first.referenceStates[0]) == .manyToMany)
    #expect(encoder.links(for: fixture.swift, in: .records).isEmpty)
}

@Test func addingAManyToManyInverseKeepsLinkIDs() {
    let sourceID = UUID(), targetID = UUID()
    let twoWay = Fixture().first.referenceStates[0]
    let oneWay = ReferenceState(schema: twoWay.schema, inverse: nil, ids: [], records: [])
    #expect(twoWay.inverse != nil)
    #expect(
        RecordLink.id(reference: oneWay, sourceType: "Post", sourceID: sourceID, targetID: targetID)
            == RecordLink.id(reference: twoWay, sourceType: "Post", sourceID: sourceID, targetID: targetID)
    )
}

@Test func bothSidesDecodeManyToMany() throws {
    let fixture = Fixture()
    let links = fixture.links
    let topicRecords = [fixture.record(fixture.swift), fixture.record(fixture.ios)]

    let firstAgain = try decoder.decode(
        Post.self, from: encoder.encode(fixture.first, in: .records), links: links, targets: topicRecords
    )
    #expect(firstAgain.topics.map(\.name) == ["Swift", "iOS"])
    #expect(Set(firstAgain.topics[0].postIDs) == [fixture.first.id, fixture.second.id]) // one level deep
    #expect(firstAgain.topics[1].postIDs == [fixture.first.id])

    let swiftAgain = try decoder.decode(Topic.self, from: topicRecords[0], links: links)
    #expect(Set(swiftAgain.postIDs) == [fixture.first.id, fixture.second.id])
    let iosAgain = try decoder.decode(Topic.self, from: topicRecords[1], links: links)
    #expect(iosAgain.postIDs == [fixture.first.id])
    #expect(encoder.links(for: swiftAgain, in: .records).isEmpty)
}

@Test func removingATopicRemovesThePostFromIt() throws {
    let fixture = Fixture()
    let saved = encoder.links(for: fixture.first, in: .records)
    var post = try decoder.decode(
        Post.self, from: encoder.encode(fixture.first, in: .records),
        links: fixture.links, targets: [fixture.record(fixture.swift), fixture.record(fixture.ios)]
    )
    post._topics.values = [fixture.swift]

    let removed = encoder.changes(for: post, from: saved).deletes
    #expect(removed.count == 1)
    let remaining = fixture.links.filter { !removed.contains($0.recordID) }
    let iosAgain = try decoder.decode(Topic.self, from: fixture.record(fixture.ios), links: remaining)
    #expect(iosAgain.postIDs.isEmpty)
}
