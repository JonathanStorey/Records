import CloudKit
import Testing
@testable import Records

/// Record types for link tests, namespaced so they don't clash with other test records.
enum LinkFixtures {
    @Record struct User { var id: UUID }
    @Record struct Profile { var id: UUID }
    @Record struct Note { var id: UUID }
    @Record struct Folder { var id: UUID }
    @Record struct Tag { var id: UUID }
    @Record struct Person { var id: UUID }
}

/// Short name for the fixtures. Bare names like `Note` clash with other test records.
private typealias F = LinkFixtures

// MARK: - Signatures

@Test(arguments: [
    ("User.profile:Profile <-> Profile.user:User", Relationship.oneToOne),
    ("Note.folder:Folder <-> Folder.notes:[Note]", .manyToOne),
    ("Folder.notes:[Note] <-> Note.folder:Folder", .oneToMany),
    ("Note.tags:[Tag] <-> Tag.notes:[Note]", .manyToMany),
    ("Note.author:Person", .manyToOne),
    ("Note.tags:[Tag]", .manyToMany),
])
func signatureKind(signature: String, kind: Relationship) throws {
    #expect(try Relationship(signature: signature) == kind)
}

@Test(arguments: [
    "",
    "Note.tags",
    "Note:[Tag]",
    "Note.tags:[Tag",
    "Note.tags:[Tag]<->Tag.notes:[Note]",
    "Note.tags:[Tag] <-> Tag.notes:[Folder]",
    "Note.tags:[Tag] <-> Tag.notes:[Note] <-> Note.x:Tag",
    "Note.my tags:[Tag]",
])
func invalidSignatureThrows(signature: String) {
    #expect(throws: RecordLinkError.invalidSignature(signature)) {
        try Relationship(signature: signature)
    }
}

// MARK: - Factories

@Test func factoriesBuildCanonicalSignatures() throws {
    let user = F.User(id: UUID()), note = F.Note(id: UUID()), folder = F.Folder(id: UUID())

    let cases: [(RecordLink, String)] = try [
        (RecordLink.oneToOne(from: user, property: "profile", to: F.Profile.self, id: UUID(), inverse: "user"),
         "User.profile:Profile <-> Profile.user:User"),
        (RecordLink.oneToMany(from: folder, property: "notes", to: F.Note.self, id: UUID(), inverse: "folder", order: "a0"),
         "Folder.notes:[Note] <-> Note.folder:Folder"),
        (RecordLink.manyToOne(from: note, property: "folder", to: F.Folder.self, id: UUID(), inverse: "notes"),
         "Note.folder:Folder <-> Folder.notes:[Note]"),
        (RecordLink.manyToOne(from: note, property: "author", to: F.Person.self, id: UUID()),
         "Note.author:Person"),
        (RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: UUID(), inverse: "notes", order: "a0"),
         "Note.tags:[Tag] <-> Tag.notes:[Note]"),
        (RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: UUID(), order: "a0"),
         "Note.tags:[Tag]"),
    ]
    for (link, signature) in cases {
        #expect(link.relationship == signature)
    }
}

@Test func linkStoresItsFields() throws {
    let note = F.Note(id: UUID()), folderID = UUID()
    let link = try RecordLink.manyToOne(
        from: note, property: "folder", to: F.Folder.self, id: folderID, inverse: "notes", deleteSelf: true
    )
    #expect(link.sourceName == note.id.uuidString)
    #expect(link.targetName == folderID.uuidString)
    #expect(link.deleteSelf)
    #expect(link.order == nil)
    #expect(try link.kind == .manyToOne)
}

@Test func deleteSelfDefaultsToFalse() throws {
    let link = try RecordLink.manyToOne(from: F.Note(id: UUID()), property: "author", to: F.Person.self, id: UUID())
    #expect(!link.deleteSelf)
}

@Test func deleteSelfWithoutInverseThrows() {
    #expect(throws: RecordLinkError.deleteSelfRequiresInverse) {
        try RecordLink.manyToMany(
            from: F.Note(id: UUID()), property: "tags", to: F.Tag.self, id: UUID(), deleteSelf: true, order: "a0"
        )
    }
}

@Test func invalidPropertyNameThrows() {
    #expect(throws: RecordLinkError.invalidSignature("Note.my tags:[Tag]")) {
        try RecordLink.manyToMany(from: F.Note(id: UUID()), property: "my tags", to: F.Tag.self, id: UUID(), order: "a0")
    }
}

@Test func oneToManyKeepsTheOwningSideAsSource() throws {
    let folder = F.Folder(id: UUID()), noteID = UUID()
    let link = try RecordLink.oneToMany(
        from: folder, property: "notes", to: F.Note.self, id: noteID, inverse: "folder", deleteSelf: true, order: "a0"
    )
    #expect(link.sourceName == folder.id.uuidString)
    #expect(link.targetName == noteID.uuidString)
    #expect(link.order == "a0")
}

// MARK: - Identity

@Test func idIsAValidVersion8UUID() throws {
    let link = try RecordLink.manyToOne(from: F.Note(id: UUID()), property: "author", to: F.Person.self, id: UUID())
    let bytes = link.id.uuid
    #expect(bytes.6 >> 4 == 0x8)
    #expect(bytes.8 >> 6 == 0b10)
    #expect(UUID(uuidString: link.id.uuidString) == link.id)
}

@Test func toOneLinkKeepsItsIDWhenTargetChanges() throws {
    let note = F.Note(id: UUID())
    let first = try RecordLink.manyToOne(from: note, property: "folder", to: F.Folder.self, id: UUID())
    let second = try RecordLink.manyToOne(from: note, property: "folder", to: F.Folder.self, id: UUID())
    #expect(first.id == second.id)
}

@Test func oneToManyLinkKeepsItsIDWhenSourceChanges() throws {
    let noteID = UUID()
    let first = try RecordLink.oneToMany(
        from: F.Folder(id: UUID()), property: "notes", to: F.Note.self, id: noteID, inverse: "folder", order: "a0"
    )
    let second = try RecordLink.oneToMany(
        from: F.Folder(id: UUID()), property: "notes", to: F.Note.self, id: noteID, inverse: "folder", order: "a0"
    )
    #expect(first.id == second.id)
}

@Test func manyToManyLinkIsOnePerPair() throws {
    let note = F.Note(id: UUID()), tag1 = UUID(), tag2 = UUID()
    let a = try RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: tag1, order: "a0")
    let b = try RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: tag1, order: "b0")
    let c = try RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: tag2, order: "a0")
    #expect(a.id == b.id)
    #expect(a.id != c.id)
}

@Test func differentPropertiesToSameTargetDoNotCollide() throws {
    let note = F.Note(id: UUID()), personID = UUID()
    let author = try RecordLink.manyToOne(from: note, property: "author", to: F.Person.self, id: personID)
    let editor = try RecordLink.manyToOne(from: note, property: "editor", to: F.Person.self, id: personID)
    #expect(author.id != editor.id)
}

@Test func addingAnInverseKeepsLinkIDs() throws {
    let note = F.Note(id: UUID()), tagID = UUID(), personID = UUID()

    let tagsBefore = try RecordLink.manyToMany(from: note, property: "tags", to: F.Tag.self, id: tagID, order: "a0")
    let tagsAfter = try RecordLink.manyToMany(
        from: note, property: "tags", to: F.Tag.self, id: tagID, inverse: "notes", order: "a0"
    )
    #expect(tagsBefore.id == tagsAfter.id)

    let authorBefore = try RecordLink.manyToOne(from: note, property: "author", to: F.Person.self, id: personID)
    let authorAfter = try RecordLink.manyToOne(
        from: note, property: "author", to: F.Person.self, id: personID, inverse: "notes"
    )
    #expect(authorBefore.id == authorAfter.id)
}

// MARK: - Encoding

@Test func linkEncodesAndDecodesLikeAnyRecord() throws {
    let link = try RecordLink.manyToMany(
        from: F.Note(id: UUID()), property: "tags", to: F.Tag.self, id: UUID(), inverse: "notes", order: "a0"
    )
    let record = CKRecordEncoder().encode(link, in: "Notes")

    #expect(record.recordType == "RecordLink")
    #expect(record.recordID.recordName == link.id.uuidString)
    #expect(record.recordID.zoneID.zoneName == "Notes")
    #expect(record["relationship"] as? String == "Note.tags:[Tag] <-> Tag.notes:[Note]")
    #expect(record["deleteSelf"] as? Bool == false)
    #expect(record["order"] as? String == "a0")
    #expect(record.parent == nil)
    #expect(try CKRecordDecoder().decode(RecordLink.self, from: record) == link)
}

@Test func toOneLinkLeavesOrderUnset() throws {
    let link = try RecordLink.manyToOne(from: F.Note(id: UUID()), property: "author", to: F.Person.self, id: UUID())
    let record = CKRecordEncoder().encode(link, in: "Notes")
    #expect(!record.allKeys().contains("order"))
}
