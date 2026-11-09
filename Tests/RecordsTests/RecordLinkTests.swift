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

@Test func linkStoresFieldsAndParent() throws {
    let link = try CKRecord.Link(
        relationship: "Note.folder:Folder <-> Folder.notes:[Note]",
        source: recordID("note-1"),
        target: recordID("folder-1"),
        sourceRule: .nullify,
        targetRule: .cascade
    )

    #expect(link.recordType == CKRecord.linkRecordType)
    #expect(link.recordID.zoneID == zone())
    #expect(link.recordID.recordName.hasPrefix("link-"))
    #expect(link.recordID.recordName.count == 69)
    #expect(link[CKRecord.LinkKey.relationship] as? String == "Note.folder:Folder <-> Folder.notes:[Note]")
    #expect(link[CKRecord.LinkKey.sourceName] as? String == "note-1")
    #expect(link[CKRecord.LinkKey.targetName] as? String == "folder-1")
    #expect(link[CKRecord.LinkKey.sourceRule] as? String == "nullify")
    #expect(link[CKRecord.LinkKey.targetRule] as? String == "cascade")
    #expect(link[CKRecord.LinkKey.version] as? Int64 == 1)
    #expect(link[CKRecord.LinkKey.order] == nil)
    #expect(link.parent?.recordID == recordID("note-1"))
}

@Test func toOneLinkOverwritesWhenTargetChanges() throws {
    let signature = "Note.folder:Folder <-> Folder.notes:[Note]"
    let first = try CKRecord.Link(relationship: signature, source: recordID("note-1"), target: recordID("folder-1"))
    let second = try CKRecord.Link(relationship: signature, source: recordID("note-1"), target: recordID("folder-2"))
    #expect(first.recordID == second.recordID)
}

@Test func oneToManyLinkOverwritesWhenSourceChanges() throws {
    let signature = "Folder.notes:[Note] <-> Note.folder:Folder"
    let first = try CKRecord.Link(relationship: signature, source: recordID("folder-1"), target: recordID("note-1"))
    let second = try CKRecord.Link(relationship: signature, source: recordID("folder-2"), target: recordID("note-1"))
    #expect(first.recordID == second.recordID)
}

@Test func manyToManyLinkIsOnePerPair() throws {
    let signature = "Note.tags:[Tag] <-> Tag.notes:[Note]"
    let a = try CKRecord.Link(relationship: signature, source: recordID("note-1"), target: recordID("tag-1"))
    let b = try CKRecord.Link(relationship: signature, source: recordID("note-1"), target: recordID("tag-1"))
    let c = try CKRecord.Link(relationship: signature, source: recordID("note-1"), target: recordID("tag-2"))
    #expect(a.recordID == b.recordID)
    #expect(a.recordID != c.recordID)
}

@Test func differentPropertiesToSameTargetDoNotCollide() throws {
    let author = try CKRecord.Link(relationship: "Note.author:Person", source: recordID("note-1"), target: recordID("person-1"))
    let editor = try CKRecord.Link(relationship: "Note.editor:Person", source: recordID("note-1"), target: recordID("person-1"))
    #expect(author.recordID != editor.recordID)
}

@Test func orderIsStoredWhenGiven() throws {
    let link = try CKRecord.Link(
        relationship: "Note.tags:[Tag] <-> Tag.notes:[Note]",
        source: recordID("note-1"),
        target: recordID("tag-1"),
        order: "a0"
    )
    #expect(link[CKRecord.LinkKey.order] as? String == "a0")
}

@Test func crossZoneLinkThrows() {
    let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
    #expect(throws: RecordLinkError.zoneMismatch) {
        try CKRecord.Link(
            relationship: "Note.author:Person",
            source: recordID("note-1"),
            target: recordID("person-1", in: otherZone)
        )
    }
}
