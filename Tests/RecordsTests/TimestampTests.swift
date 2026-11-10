import CloudKit
import Foundation
import Records
import Testing

@Record
struct Memo: Equatable {
    var id: UUID
    var text: String
    @Timestamped(.created) var createdAt: Date?
    @Timestamped(.modified) var modifiedAt: Date?
}

@Test func timestampsAreNilUntilTheFirstSave() {
    let memo = Memo(id: UUID(), text: "Call back")
    #expect(memo.createdAt == nil)
    #expect(memo.modifiedAt == nil)
}

@Test func timestampsAreNotFields() {
    let memo = Memo(id: UUID(), text: "Call back")
    let record = CKRecordEncoder().encode(memo, in: .records)
    #expect(record.allKeys() == ["text"])
}

// CloudKit sets a record's dates only on the server, so the macro tests check that decoding reads
// `creationDate` and `modificationDate`.
@Test func anUnsavedRecordDecodesWithoutDates() throws {
    let record = CKRecordEncoder().encode(Memo(id: UUID(), text: "Call back"), in: .records)
    let memo = try CKRecordDecoder().decode(Memo.self, from: record)
    #expect(memo.createdAt == nil)
    #expect(memo.modifiedAt == nil)
}

@Test func theMemberwiseInitializerLeavesTimestampsOut() {
    // Compiles only because the initializer takes no dates.
    let memo = Memo(id: UUID(), text: "Call back")
    #expect(memo.createdAt == nil)
}
