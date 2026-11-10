import CloudKit
import Testing
@testable import Records

/// A `@Reference` as its declarations describe it. `inverse` is the target's `from:` side.
private func reference(
    _ property: String, to target: String, many: Bool = false, inverse: (name: String, many: Bool)? = nil
) -> ReferenceState {
    ReferenceState(
        property: property, targetType: target, isToMany: many, isSorted: false,
        inverse: inverse.map { Inverse(property: $0.name, isToMany: $0.many, deleteSelf: false) },
        ids: []
    )
}

private func link(
    _ reference: ReferenceState, from sourceType: String = "Note", id sourceID: UUID = UUID(),
    to targetID: UUID = UUID(), order: String? = nil
) -> RecordLink {
    RecordLink(reference: reference, sourceType: sourceType, sourceID: sourceID, target: ReferenceTarget(id: targetID, order: order))
}

// MARK: - Computed from the declarations

@Test func signatureIsComputedFromTheDeclarations() {
    let cases: [(ReferenceState, String, String)] = [
        (reference("profile", to: "Profile", inverse: ("user", false)), "User", "User.profile:Profile <-> Profile.user:User"),
        (reference("folder", to: "Folder", inverse: ("notes", true)), "Note", "Note.folder:Folder <-> Folder.notes:[Note]"),
        (reference("notes", to: "Note", many: true, inverse: ("folder", false)), "Folder", "Folder.notes:[Note] <-> Note.folder:Folder"),
        (reference("tags", to: "Tag", many: true, inverse: ("notes", true)), "Note", "Note.tags:[Tag] <-> Tag.notes:[Note]"),
        (reference("author", to: "Person"), "Note", "Note.author:Person"),
        (reference("tags", to: "Tag", many: true), "Note", "Note.tags:[Tag]"),
    ]
    for (reference, sourceType, signature) in cases {
        #expect(RecordLink.signature(of: reference, in: sourceType) == signature)
    }
}

@Test func kindComesFromBothSides() {
    #expect(Relationship(reference("profile", to: "Profile", inverse: ("user", false))) == .oneToOne)
    #expect(Relationship(reference("folder", to: "Folder", inverse: ("notes", true))) == .manyToOne)
    #expect(Relationship(reference("notes", to: "Note", many: true, inverse: ("folder", false))) == .oneToMany)
    #expect(Relationship(reference("tags", to: "Tag", many: true, inverse: ("notes", true))) == .manyToMany)
    #expect(Relationship(reference("author", to: "Person")) == .manyToOne)
    #expect(Relationship(reference("tags", to: "Tag", many: true)) == .manyToMany)
}

// MARK: - Stored data

@Test func linkStoresOnlyItsSourceAndTarget() {
    let noteID = UUID(), folderID = UUID()
    let stored = link(reference("folder", to: "Folder", inverse: ("notes", true)), id: noteID, to: folderID)
    #expect(stored.source == "Note.folder")
    #expect(stored.sourceType == "Note")
    #expect(stored.sourceProperty == "folder")
    #expect(stored.sourceName == noteID.uuidString)
    #expect(stored.targetName == folderID.uuidString)
    #expect(stored.order == nil)
    #expect(stored.assetID == nil)
}

@Test func renamingAnInverseChangesNothingStored() {
    let noteID = UUID(), tagID = UUID()
    let before = link(reference("tags", to: "Tag", many: true, inverse: ("notes", true)), id: noteID, to: tagID, order: "a0")
    let after = link(reference("tags", to: "Tag", many: true, inverse: ("pages", true)), id: noteID, to: tagID, order: "a0")
    #expect(before == after)
}

// MARK: - Identity

@Test func idIsAValidVersion8UUID() {
    let bytes = link(reference("author", to: "Person")).id.uuid
    #expect(bytes.6 >> 4 == 0x8)
    #expect(bytes.8 >> 6 == 0b10)
}

@Test func toOneLinkKeepsItsIDWhenTargetChanges() {
    let noteID = UUID(), folder = reference("folder", to: "Folder")
    #expect(link(folder, id: noteID).id == link(folder, id: noteID).id)
}

@Test func oneToManyLinkKeepsItsIDWhenSourceChanges() {
    let noteID = UUID(), notes = reference("notes", to: "Note", many: true, inverse: ("folder", false))
    #expect(link(notes, from: "Folder", to: noteID).id == link(notes, from: "Folder", to: noteID).id)
}

@Test func manyToManyLinkIsOnePerPair() {
    let noteID = UUID(), tagID = UUID(), tags = reference("tags", to: "Tag", many: true)
    #expect(link(tags, id: noteID, to: tagID, order: "a0").id == link(tags, id: noteID, to: tagID, order: "b0").id)
    #expect(link(tags, id: noteID, to: tagID).id != link(tags, id: noteID, to: UUID()).id)
}

@Test func differentPropertiesToSameTargetDoNotCollide() {
    let noteID = UUID(), personID = UUID()
    let author = link(reference("author", to: "Person"), id: noteID, to: personID)
    let editor = link(reference("editor", to: "Person"), id: noteID, to: personID)
    #expect(author.id != editor.id)
}

@Test func addingAnInverseKeepsLinkIDs() {
    let noteID = UUID(), tagID = UUID(), personID = UUID()
    #expect(
        link(reference("tags", to: "Tag", many: true), id: noteID, to: tagID).id
            == link(reference("tags", to: "Tag", many: true, inverse: ("notes", true)), id: noteID, to: tagID).id
    )
    #expect(
        link(reference("author", to: "Person"), id: noteID, to: personID).id
            == link(reference("author", to: "Person", inverse: ("notes", true)), id: noteID, to: personID).id
    )
}

// MARK: - Encoding

@Test func linkEncodesAndDecodesLikeAnyRecord() throws {
    let stored = link(reference("tags", to: "Tag", many: true, inverse: ("notes", true)), order: "a0")
    let record = CKRecordEncoder().encode(stored, in: "Notes")

    #expect(record.recordType == "RecordLink")
    #expect(record.recordID.recordName == stored.id.uuidString)
    #expect(record.recordID.zoneID.zoneName == "Notes")
    #expect(Set(record.allKeys()) == ["source", "sourceName", "targetName", "order"])
    #expect(record["source"] as? String == "Note.tags")
    #expect(record.parent == nil)
    #expect(try CKRecordDecoder().decode(RecordLink.self, from: record) == stored)
}

@Test func toOneLinkLeavesOrderUnset() {
    let record = CKRecordEncoder().encode(link(reference("author", to: "Person")), in: "Notes")
    #expect(!record.allKeys().contains("order"))
}

// MARK: - Fixed IDs

/// Link IDs are stored in CloudKit, so the same inputs must give the same ID forever. If one of
/// these changes, every link already synced would be orphaned.
@Test func linkIDsNeverChange() {
    let source = "00000000-0000-0000-0000-00000000000A"
    let target = "00000000-0000-0000-0000-00000000000B"
    let id = { (kind: Relationship) in
        RecordLink.id(source: "Album.tracks", kind: kind, sourceName: source, targetName: target).uuidString
    }
    #expect(id(.oneToOne) == "517FD3D4-BD65-87DC-9477-49F405E6253A")
    #expect(id(.manyToOne) == "517FD3D4-BD65-87DC-9477-49F405E6253A")
    #expect(id(.oneToMany) == "AF241C24-FAC0-853E-9BF7-0459C08CB8A9")
    #expect(id(.manyToMany) == "25B987EA-080B-8F2E-9F39-2E48426701A4")

    let asset = RecordLink(
        asset: AssetState(property: "cover", id: nil, fileURL: nil), assetID: UUID(),
        sourceType: "Album", sourceID: UUID(uuidString: source)!
    )
    #expect(asset.id.uuidString == "B308A57E-3AD9-81D6-9252-AB80BB9E83CD")
}
