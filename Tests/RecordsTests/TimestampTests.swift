import CloudKit
import Foundation
import ObjectiveC
import Records
import Testing

@Record
struct Memo: Equatable {
    var id: UUID
    var text: String
    @Timestamped(.created) var createdAt: Date?
    @Timestamped(.modified) var modifiedAt: Date?
}

/// Sets a server date on `record` the way a fetched record carries it.
private func setServerDate(_ date: Date, _ key: String, on record: CKRecord) throws {
    try #require(class_getInstanceVariable(CKRecord.self, "_\(key)") != nil)
    record.setValue(date, forKey: key)
}

@Test func timestampsAreNilUntilTheFirstSave() {
    let memo = Memo(id: UUID(), text: "Call back")
    #expect(memo.createdAt == nil)
    #expect(memo.modifiedAt == nil)
}

@Test func timestampsAreNeitherFieldsNorChanges() {
    let memo = Memo(id: UUID(), text: "Call back")
    #expect(memo.changedFields == ["text"])
    let record = CKRecordEncoder().encode(memo, in: .records)
    #expect(record.allKeys() == ["text"])
}

@Test func timestampsReadTheServerDates() throws {
    let record = CKRecordEncoder().encode(Memo(id: UUID(), text: "Call back"), in: .records)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let modified = Date(timeIntervalSince1970: 1_700_086_400)
    try setServerDate(created, "creationDate", on: record)
    try setServerDate(modified, "modificationDate", on: record)

    let memo = try CKRecordDecoder().decode(Memo.self, from: record)
    #expect(memo.createdAt == created)
    #expect(memo.modifiedAt == modified)
    #expect(!memo.hasChanges)
}
