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

extension Zone {
    static let records: Zone = "Records"
}

private func zone() -> CKRecordZone.ID {
    Zone.records.zoneID
}

@Test func encodesIdentityAndFields() {
    let id = UUID()
    let created = Date(timeIntervalSince1970: 1_000)
    let note = Note(id: id, title: "Groceries", isPinned: true, rating: nil, tags: ["home", "food"], created: created)

    let record = CKRecordEncoder().encode(note, in: .records)

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
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(record["rating"] as? Int == 4)
}

@Test func explicitNameSetsRecordType() {
    let folder = LegacyFolder(id: UUID(), name: "Inbox")
    let record = CKRecordEncoder().encode(folder, in: .records)
    #expect(LegacyFolder.recordType == "Folder")
    #expect(record.recordType == "Folder")
    #expect(record["name"] as? String == "Inbox")
}

@Test func genericRecordUsesItsName() {
    let box = Box(id: UUID(), value: "hello")
    let record = CKRecordEncoder().encode(box, in: .records)
    #expect(record.recordType == "Box")
    #expect(record["value"] as? String == "hello")
}

// MARK: - Decoding

@Test func roundTripsThroughCKRecord() throws {
    let note = Note(
        id: UUID(), title: "Groceries", isPinned: true, rating: 3,
        tags: ["home"], created: Date(timeIntervalSince1970: 1_000)
    )
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

@Test func missingOptionalDecodesAsNil() throws {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let decoded = try CKRecordDecoder().decode(Note.self, from: CKRecordEncoder().encode(note, in: .records))
    #expect(decoded.rating == nil)
}

@Test func roundTripsExplicitNameAndGeneric() throws {
    let folder = LegacyFolder(id: UUID(), name: "Inbox")
    let box = Box(id: UUID(), value: 42)
    #expect(try CKRecordDecoder().decode(LegacyFolder.self, from: CKRecordEncoder().encode(folder, in: .records)) == folder)
    #expect(try CKRecordDecoder().decode(Box<Int>.self, from: CKRecordEncoder().encode(box, in: .records)) == box)
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

// MARK: - Encoding into an existing record

@Test func encodeIntoUpdatesTheSameRecord() throws {
    var note = Note(id: UUID(), title: "Draft", isPinned: false, rating: 2, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: .records)

    note.title = "Final"
    note.rating = nil
    try CKRecordEncoder().encode(note, into: record)

    #expect(record["title"] as? String == "Final")
    #expect(record["rating"] == nil)
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

@Test func encodeIntoWrongRecordTypeThrows() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let folder = CKRecord(recordType: "Folder", recordID: CKRecord.ID(recordName: note.id.uuidString, zoneID: zone()))
    #expect(throws: CKRecordEncodingError.recordTypeMismatch(expected: "Note", found: "Folder")) {
        try CKRecordEncoder().encode(note, into: folder)
    }
}

@Test func encodeIntoWrongRecordNameThrows() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let other = CKRecord(recordType: "Note", recordID: CKRecord.ID(recordName: "other", zoneID: zone()))
    #expect(throws: CKRecordEncodingError.recordNameMismatch(expected: note.id.uuidString, found: "other")) {
        try CKRecordEncoder().encode(note, into: other)
    }
}

// MARK: - nil and empty values

@Test func nilOptionalLeavesNoField() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: ["x"], created: .now)
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(!record.allKeys().contains("rating"))
}

@Test func missingArrayFieldDecodesAsEmpty() throws {
    // CloudKit drops empty lists, so a saved `tags: []` comes back with no field.
    let record = noteRecord()
    record["tags"] = nil
    let note = try CKRecordDecoder().decode(Note.self, from: record)
    #expect(note.tags == [])
}

@Test func emptyArrayRoundTrips() throws {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: Date(timeIntervalSince1970: 0))
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

// MARK: - Zone

@Test func zoneFromStringLiteral() {
    let zone: Zone = "Notes"
    #expect(zone.name == "Notes")
    #expect(zone.ownerName == CKCurrentUserDefaultName)
    #expect(zone.zoneID == CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName))
}

@Test func zoneRoundTripsThroughZoneID() {
    let sharedID = CKRecordZone.ID(zoneName: "Shared", ownerName: "_abc123")
    let shared = Zone(sharedID)
    #expect(shared.zoneID == sharedID)
    #expect(shared.ownerName == "_abc123")
    #expect(shared != "Shared")
}

@Test func encoderUsesTheZone() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: "Inbox")
    #expect(record.recordID.zoneID.zoneName == "Inbox")
}
