import CloudKit
import Records
import Testing

@Record
struct Counter: Equatable {
    var id: UUID
    var name: String
    var count: Int = 0
    let created: Date
}

private func saved<R: Record>(_ record: R) throws -> (R, CKRecord) {
    let ckRecord = CKRecordEncoder().encode(record, in: .records)
    return (try CKRecordDecoder().decode(R.self, from: ckRecord), ckRecord)
}

@Test func aRecordMadeInCodeHasEveryFieldChanged() {
    let note = Note(id: UUID(), title: "A", isPinned: false, rating: nil, tags: [], created: .now)
    #expect(note.changedFields == ["title", "isPinned", "rating", "tags", "created"])
    #expect(note.hasChanges)
}

@Test func aDecodedRecordStartsUnchanged() throws {
    let (note, _) = try saved(Note(id: UUID(), title: "A", isPinned: false, rating: 2, tags: ["x"], created: .now))
    #expect(note.changedFields.isEmpty)
    #expect(!note.hasChanges)
}

@Test func settingAFieldMarksOnlyThatField() throws {
    var (note, _) = try saved(Note(id: UUID(), title: "A", isPinned: false, rating: 2, tags: ["x"], created: .now))
    note.title = "B"
    note.tags.append("y")
    #expect(note.changedFields == ["title", "tags"])
    #expect(note.hasChanges)
}

@Test func settingTheSameValueStillCounts() throws {
    var (note, _) = try saved(Note(id: UUID(), title: "A", isPinned: false, rating: 2, tags: [], created: .now))
    note.title = "A"
    #expect(note.changedFields == ["title"])
}

@Test func markSavedClearsFieldsAndReferences() throws {
    var article = Article(id: UUID(), title: "A", author: nil, editorID: UUID())
    #expect(article.hasChanges)
    article.markSaved()
    #expect(article.changedFields.isEmpty)
    #expect(!article.hasChanges)

    article.editorID = nil
    #expect(article.changedFields.isEmpty)
    #expect(article.hasChanges)
}

@Test func encodeIntoWritesOnlyChangedFields() throws {
    var (note, serverRecord) = try saved(Note(id: UUID(), title: "A", isPinned: false, rating: 2, tags: [], created: .now))
    // Another device changed the rating after this copy was loaded.
    serverRecord["rating"] = 5

    note.title = "B"
    try CKRecordEncoder().encode(note, into: serverRecord)

    #expect(serverRecord["title"] as? String == "B")
    #expect(serverRecord["rating"] as? Int == 5)
}

@Test func clearingAFieldClearsItsValue() throws {
    var (note, serverRecord) = try saved(Note(id: UUID(), title: "A", isPinned: false, rating: 2, tags: [], created: .now))
    note.rating = nil
    try CKRecordEncoder().encode(note, into: serverRecord)
    #expect(serverRecord["rating"] == nil)
}

@Test func anInitialValueIsStillTheDefault() throws {
    let counter = Counter(id: UUID(), name: "Taps", created: .now)
    #expect(counter.count == 0)
    // A `let` can't change, so it is never reported.
    #expect(counter.changedFields == ["name", "count"])

    let (decoded, _) = try saved(counter)
    #expect(decoded == counter)
    #expect(decoded.changedFields.isEmpty)
}

@Test func equalityIgnoresWhetherFieldsChanged() throws {
    let note = Note(id: UUID(), title: "A", isPinned: true, rating: nil, tags: [], created: Date(timeIntervalSince1970: 1))
    let (decoded, _) = try saved(note)
    #expect(note.hasChanges)
    #expect(!decoded.hasChanges)
    #expect(decoded == note)
}
