import CloudKit
import Records
import Testing

@Record
struct Note: Equatable {
    var title: String
    var isPinned: Bool
    var rating: Int?
    var tags: [String]
    var created: Date
    var summary: String { "\(title) (\(tags.count))" }
}

@Record("Folder")
struct LegacyFolder: Equatable {
    var name: String
}

@Record("Box")
struct Box<Value: CKRecordValueProtocol & Equatable>: Equatable {
    var value: Value
}

@Record
struct Person: Equatable {
    var name: String
}

@Record
struct Article {
    var title: String
    @Reference var author: Person?
    @Reference var editor: Person?
}

private func zone() -> CKRecordZone.ID {
    Zone.records.zoneID
}

@Test func encodesIdentityAndFields() {
    let id = Note.ID()
    let created = Date(timeIntervalSince1970: 1_000)
    let note = Note(title: "Groceries", isPinned: true, rating: nil, tags: ["home", "food"], created: created, id: id)

    let record = CKRecordEncoder().encode(note, in: .records)

    #expect(record.recordType == "Note")
    #expect(record.recordID.recordName == id.uuid.uuidString)
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
    let note = Note(title: "A", isPinned: false, rating: 4, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(record["rating"] as? Int == 4)
}

@Test func explicitNameSetsRecordType() {
    let folder = LegacyFolder(name: "Inbox")
    let record = CKRecordEncoder().encode(folder, in: .records)
    #expect(LegacyFolder.recordType == "Folder")
    #expect(record.recordType == "Folder")
    #expect(record["name"] as? String == "Inbox")
}

@Test func genericRecordUsesItsName() {
    let box = Box(value: "hello")
    let record = CKRecordEncoder().encode(box, in: .records)
    #expect(record.recordType == "Box")
    #expect(record["value"] as? String == "hello")
}

// MARK: - Decoding

@Test func roundTripsThroughCKRecord() throws {
    let note = Note(
        title: "Groceries", isPinned: true, rating: 3,
        tags: ["home"], created: Date(timeIntervalSince1970: 1_000)
    )
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

@Test func missingOptionalDecodesAsNil() throws {
    let note = Note(title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let decoded = try CKRecordDecoder().decode(Note.self, from: CKRecordEncoder().encode(note, in: .records))
    #expect(decoded.rating == nil)
}

@Test func roundTripsExplicitNameAndGeneric() throws {
    let folder = LegacyFolder(name: "Inbox")
    let box = Box(value: 42)
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
    #expect(note.id.uuid == id)
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

@Test func anUploadOverwritesTheServersRecord() throws {
    var note = Note(title: "Draft", isPinned: false, rating: 2, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: .records)

    note.title = "Final"
    note.rating = nil
    let sent = try upload(note, onto: record)

    #expect(sent.recordID == record.recordID)
    #expect(sent["title"] as? String == "Final")
    #expect(sent["rating"] == nil)
    #expect(try CKRecordDecoder().decode(Note.self, from: sent) == note)
}

// MARK: - nil and empty values

@Test func nilOptionalLeavesNoField() {
    let note = Note(title: "A", isPinned: false, rating: nil, tags: ["x"], created: .now)
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
    let note = Note(title: "A", isPinned: false, rating: nil, tags: [], created: Date(timeIntervalSince1970: 0))
    let record = CKRecordEncoder().encode(note, in: .records)
    #expect(try CKRecordDecoder().decode(Note.self, from: record) == note)
}

// MARK: - References

@Test func referenceIsNotWrittenAsAField() {
    let author = Person(name: "Ada")
    let article = Article(title: "Notes", author: author, editor: Person(name: "Grace"))
    let record = CKRecordEncoder().encode(article, in: .records)
    #expect(Set(record.allKeys()) == ["title"])
}

@Test func referenceDecodesAsNil() throws {
    let article = Article(title: "Notes", author: Person(name: "Ada"), editor: Person(name: "Grace"))
    let decoded = try CKRecordDecoder().decode(Article.self, from: CKRecordEncoder().encode(article, in: .records))
    #expect(decoded.title == "Notes")
    #expect(decoded.author == nil)
    #expect(decoded.editor == nil)
}

@Test func referenceCanBeNilInMemberwiseInit() {
    let article = Article(title: "Notes", author: nil, editor: nil)
    #expect(article.author == nil)
    #expect(article.editor == nil)
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
    let note = Note(title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    let record = CKRecordEncoder().encode(note, in: "Inbox")
    #expect(record.recordID.zoneID.zoneName == "Inbox")
}
