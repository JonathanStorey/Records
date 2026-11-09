import CloudKit
import Records
import Testing

@Record
struct Note {
    var id: UUID
    var title: String
    var isPinned: Bool
    var rating: Int?
    var tags: [String]
    var created: Date
    var summary: String { "\(title) (\(tags.count))" }
}

@Record("Folder")
struct LegacyFolder {
    let id: UUID
    var name: String
}

@Record("Box")
struct Box<Value: CKRecordValueProtocol> {
    var id: UUID
    var value: Value
}

private func zone() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "Records", ownerName: CKCurrentUserDefaultName)
}

@Test func encodesIdentityAndFields() {
    let id = UUID()
    let created = Date(timeIntervalSince1970: 1_000)
    let note = Note(id: id, title: "Groceries", isPinned: true, rating: nil, tags: ["home", "food"], created: created)

    let record = CKRecordEncoder().encode(note, in: zone())

    #expect(record.recordType == "Note")
    #expect(record.recordID.recordName == id.uuidString)
    #expect(record.recordID.zoneID == zone())
    #expect(record["title"] as? String == "Groceries")
    #expect(record["isPinned"] as? Bool == true)
    #expect(record["rating"] == nil)
    #expect(record["tags"] as? [String] == ["home", "food"])
    #expect(record["created"] as? Date == created)
    #expect(record["id"] == nil)
    #expect(record["summary"] == nil)
    #expect(Set(record.allKeys()) == ["title", "isPinned", "tags", "created"])
}

@Test func encodesOptionalWhenSet() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: 4, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: zone())
    #expect(record["rating"] as? Int == 4)
}

@Test func explicitNameSetsRecordType() {
    let folder = LegacyFolder(id: UUID(), name: "Inbox")
    let record = CKRecordEncoder().encode(folder, in: zone())
    #expect(LegacyFolder.recordType == "Folder")
    #expect(record.recordType == "Folder")
    #expect(record["name"] as? String == "Inbox")
}

@Test func genericRecordUsesItsName() {
    let box = Box(id: UUID(), value: "hello")
    let record = CKRecordEncoder().encode(box, in: zone())
    #expect(record.recordType == "Box")
    #expect(record["value"] as? String == "hello")
}
