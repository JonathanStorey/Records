import CloudKit
import Records
import Testing

@Record
struct Note: Equatable {
    var id: UUID
    var title: String
    var isPinned: Bool
    var rating: Int?
    var tags: [String]
    var created: Date
    var summary: String { "\(title) (\(tags.count))" }
}

@Record("Folder")
struct LegacyFolder: Equatable {
    let id: UUID
    var name: String
}

@Record("Box")
struct Box<Value: CKRecordValueProtocol & Equatable>: Equatable {
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

// MARK: - Decoding

@Test func roundTripsThroughCKRecord() throws {
    let note = Note(
        id: UUID(), title: "Groceries", isPinned: true, rating: 3,
        tags: ["home"], created: Date(timeIntervalSince1970: 1_000)
    )
    let record = CKRecordEncoder().encode(note, in: zone())
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

@Test func missingOptionalDecodesAsNil() throws {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let decoded = try CKRecordDecoder().decode(Note.self, from: CKRecordEncoder().encode(note, in: zone()))
    #expect(decoded.rating == nil)
}

@Test func roundTripsExplicitNameAndGeneric() throws {
    let folder = LegacyFolder(id: UUID(), name: "Inbox")
    let box = Box(id: UUID(), value: 42)
    #expect(try CKRecordDecoder().decode(LegacyFolder.self, from: CKRecordEncoder().encode(folder, in: zone())) == folder)
    #expect(try CKRecordDecoder().decode(Box<Int>.self, from: CKRecordEncoder().encode(box, in: zone())) == box)
}

private func noteRecord(name: String = UUID().uuidString, type: String = "Note") -> CKRecord {
    let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zone()))
    record["title"] = "A"
    record["isPinned"] = false
    record["tags"] = [String]()
    record["created"] = Date.now
    return record
}

@Test func decodesARecordBuiltByHand() throws {
    let id = UUID()
    let note = try CKRecordDecoder().decode(Note.self, from: noteRecord(name: id.uuidString))
    #expect(note.id == id)
    #expect(note.title == "A")
    #expect(note.rating == nil)
}

@Test func wrongRecordTypeThrows() {
    #expect(throws: CKRecordDecodingError.recordTypeMismatch(expected: "Note", found: "Folder")) {
        try CKRecordDecoder().decode(Note.self, from: noteRecord(type: "Folder"))
    }
}

@Test func nonUUIDRecordNameThrows() {
    #expect(throws: CKRecordDecodingError.invalidRecordName("note-1")) {
        try CKRecordDecoder().decode(Note.self, from: noteRecord(name: "note-1"))
    }
}

@Test func missingFieldThrows() {
    let record = noteRecord()
    record["title"] = nil
    #expect(throws: CKRecordDecodingError.missingField("title")) {
        try CKRecordDecoder().decode(Note.self, from: record)
    }
}

@Test func wrongFieldTypeThrows() {
    let record = noteRecord()
    record["title"] = 5
    #expect(throws: CKRecordDecodingError.typeMismatch(field: "title")) {
        try CKRecordDecoder().decode(Note.self, from: record)
    }
}
