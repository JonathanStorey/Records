import CloudKit
import Testing
@testable import Records

private func zone() -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: "Records", ownerName: CKCurrentUserDefaultName)
}

private func recordID(_ name: String, in zoneID: CKRecordZone.ID = zone()) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
}

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

private func record(_ type: String, _ name: String, in zoneID: CKRecordZone.ID = zone()) -> CKRecord {
    CKRecord(recordType: type, recordID: recordID(name, in: zoneID))
}

@Test func factoriesBuildCanonicalSignatures() throws {
    let user = record("User", "user-1"), profile = record("Profile", "profile-1")
    let note = record("Note", "note-1"), folder = record("Folder", "folder-1")
    let tag = record("Tag", "tag-1"), person = record("Person", "person-1")

    let cases: [(CKRecord, String)] = try [
        (CKRecord.Link.oneToOne(source: user, property: "profile", target: profile, inverse: "user"),
         "User.profile:Profile <-> Profile.user:User"),
        (CKRecord.Link.oneToMany(source: folder, property: "notes", target: note, inverse: "folder", order: "a0"),
         "Folder.notes:[Note] <-> Note.folder:Folder"),
        (CKRecord.Link.manyToOne(source: note, property: "folder", target: folder, inverse: "notes"),
         "Note.folder:Folder <-> Folder.notes:[Note]"),
        (CKRecord.Link.manyToOne(source: note, property: "author", target: person),
         "Note.author:Person"),
        (CKRecord.Link.manyToMany(source: note, property: "tags", target: tag, inverse: "notes", order: "a0"),
         "Note.tags:[Tag] <-> Tag.notes:[Note]"),
        (CKRecord.Link.manyToMany(source: note, property: "tags", target: tag, order: "a0"),
         "Note.tags:[Tag]"),
    ]
    for (link, signature) in cases {
        #expect(link[CKRecord.LinkKey.relationship] as? String == signature)
    }
}

@Test func linkStoresFieldsAndParent() throws {
    let link = try CKRecord.Link.manyToOne(
        source: record("Note", "note-1"),
        property: "folder",
        target: record("Folder", "folder-1"),
        inverse: "notes",
        sourceRule: .nullify,
        targetRule: .cascade
    )

    #expect(link.recordType == CKRecord.linkRecordType)
    #expect(link.recordID.zoneID == zone())
    #expect(link.recordID.recordName.hasPrefix("link-"))
    #expect(link.recordID.recordName.count == 69)
    #expect(link[CKRecord.LinkKey.sourceName] as? String == "note-1")
    #expect(link[CKRecord.LinkKey.targetName] as? String == "folder-1")
    #expect(link[CKRecord.LinkKey.sourceRule] as? String == "nullify")
    #expect(link[CKRecord.LinkKey.targetRule] as? String == "cascade")
    #expect(link[CKRecord.LinkKey.version] as? Int64 == 1)
    #expect(link[CKRecord.LinkKey.order] == nil)
    #expect(link.parent?.recordID == recordID("note-1"))
}

@Test func toOneLinkOverwritesWhenTargetChanges() throws {
    let note = record("Note", "note-1")
    let first = try CKRecord.Link.manyToOne(source: note, property: "folder", target: record("Folder", "folder-1"))
    let second = try CKRecord.Link.manyToOne(source: note, property: "folder", target: record("Folder", "folder-2"))
    #expect(first.recordID == second.recordID)
}

@Test func oneToManyLinkOverwritesWhenSourceChanges() throws {
    let note = record("Note", "note-1")
    let first = try CKRecord.Link.oneToMany(source: record("Folder", "folder-1"), property: "notes", target: note, inverse: "folder", order: "a0")
    let second = try CKRecord.Link.oneToMany(source: record("Folder", "folder-2"), property: "notes", target: note, inverse: "folder", order: "a0")
    #expect(first.recordID == second.recordID)
}

@Test func manyToManyLinkIsOnePerPair() throws {
    let note = record("Note", "note-1")
    let a = try CKRecord.Link.manyToMany(source: note, property: "tags", target: record("Tag", "tag-1"), order: "a0")
    let b = try CKRecord.Link.manyToMany(source: note, property: "tags", target: record("Tag", "tag-1"), order: "a0")
    let c = try CKRecord.Link.manyToMany(source: note, property: "tags", target: record("Tag", "tag-2"), order: "a0")
    #expect(a.recordID == b.recordID)
    #expect(a.recordID != c.recordID)
}

@Test func differentPropertiesToSameTargetDoNotCollide() throws {
    let note = record("Note", "note-1"), person = record("Person", "person-1")
    let author = try CKRecord.Link.manyToOne(source: note, property: "author", target: person)
    let editor = try CKRecord.Link.manyToOne(source: note, property: "editor", target: person)
    #expect(author.recordID != editor.recordID)
}

@Test func toManyLinksAlwaysStoreOrder() throws {
    let tags = try CKRecord.Link.manyToMany(
        source: record("Note", "note-1"), property: "tags", target: record("Tag", "tag-1"), order: "a0"
    )
    let notes = try CKRecord.Link.oneToMany(
        source: record("Folder", "folder-1"), property: "notes", target: record("Note", "note-1"),
        inverse: "folder", order: "b1"
    )
    #expect(tags[CKRecord.LinkKey.order] as? String == "a0")
    #expect(notes[CKRecord.LinkKey.order] as? String == "b1")
}

@Test func invalidPropertyNameThrows() {
    #expect(throws: RecordLinkError.invalidSignature("Note.my tags:[Tag]")) {
        try CKRecord.Link.manyToMany(source: record("Note", "note-1"), property: "my tags", target: record("Tag", "tag-1"), order: "a0")
    }
}

@Test func crossZoneLinkThrows() {
    let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
    #expect(throws: RecordLinkError.zoneMismatch) {
        try CKRecord.Link.manyToOne(
            source: record("Note", "note-1"),
            property: "author",
            target: record("Person", "person-1", in: otherZone)
        )
    }
}

@Test func oneToManyKeepsTheOwningSideAsSource() throws {
    let note = record("Note", "note-1"), folder = record("Folder", "folder-1")
    let link = try CKRecord.Link.oneToMany(
        source: folder, property: "notes", target: note, inverse: "folder",
        sourceRule: .cascade, order: "a0"
    )
    #expect(link[CKRecord.LinkKey.sourceName] as? String == "folder-1")
    #expect(link[CKRecord.LinkKey.targetName] as? String == "note-1")
    #expect(link[CKRecord.LinkKey.sourceRule] as? String == "cascade")
    #expect(link[CKRecord.LinkKey.order] as? String == "a0")
    #expect(link.parent?.recordID == folder.recordID)
}

@Test func addingAnInverseKeepsLinkNames() throws {
    let note = record("Note", "note-1"), tag = record("Tag", "tag-1"), person = record("Person", "person-1")

    let tagsBefore = try CKRecord.Link.manyToMany(source: note, property: "tags", target: tag, order: "a0")
    let tagsAfter = try CKRecord.Link.manyToMany(source: note, property: "tags", target: tag, inverse: "notes", order: "a0")
    #expect(tagsBefore.recordID == tagsAfter.recordID)

    let authorBefore = try CKRecord.Link.manyToOne(source: note, property: "author", target: person)
    let authorAfter = try CKRecord.Link.manyToOne(source: note, property: "author", target: person, inverse: "notes")
    #expect(authorBefore.recordID == authorAfter.recordID)
}
