import CloudKit
import Foundation
import Testing
@testable import Records

@Record
struct Poster: Equatable {
    var title: String
    @Asset var image: Data?
}

private let png = Data("not really a png".utf8)
private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

// MARK: - Files

@Test func settingAnAssetWritesAFileNamedByItsID() throws {
    let poster = Poster(title: "Tour", image: png)
    let id = try #require(poster._image.id)
    let url = try #require(poster.$image)
    #expect(url == AssetField.url(for: id))
    #expect(url.deletingLastPathComponent().standardizedFileURL == AssetField.directory.standardizedFileURL)
    #expect(try Data(contentsOf: url) == png)
    #expect(poster.image == png)
}

@Test func eachNewValueGetsANewIDAndFile() throws {
    var poster = Poster(title: "Tour", image: png)
    let first = (poster._image.id, poster.$image)
    poster.image = Data("second".utf8)
    #expect(poster._image.id != first.0)
    #expect(poster.$image != first.1)
    #expect(poster.image == Data("second".utf8))
}

/// Setting `$image` to a file copies it in as a new asset, without reading it.
@Test func settingTheFileURLCopiesTheFileIn() throws {
    let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    try png.write(to: source)
    var poster = Poster(title: "Tour", image: nil)
    poster.$image = source

    let id = try #require(poster._image.id)
    let url = try #require(poster.$image)
    #expect(url == AssetField.url(for: id))
    #expect(url != source)
    #expect(poster.image == png)

    // The copy is the asset's own: the source can go away.
    try FileManager.default.removeItem(at: source)
    #expect(poster.image == png)
}

@Test func eachFileSetGetsANewID() throws {
    let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    try png.write(to: source)
    var poster = Poster(title: "Tour", image: nil)
    poster.$image = source
    let first = poster._image.id
    poster.$image = source
    #expect(poster._image.id != first)
    #expect(poster._image.id != nil)
}

@Test func settingTheFileURLToNilClearsTheAsset() {
    var poster = Poster(title: "Tour", image: png)
    poster.$image = nil
    #expect(poster._image.id == nil)
    #expect(poster.image == nil)
    #expect(poster.$image == nil)
}

/// A file that can't be copied is used where it is.
@Test func aFileThatCantBeCopiedIsUsedInPlace() throws {
    let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    var poster = Poster(title: "Tour", image: nil)
    poster.$image = missing
    #expect(poster._image.id != nil)
    #expect(poster.$image == missing)
    #expect(poster.image == nil)
}

@Test func anAssetMissingHereReadsTheDownloadedFile() throws {
    let downloaded = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).tmp")
    try png.write(to: downloaded)
    let field = AssetField(id: UUID(), file: downloaded)
    #expect(field.fileURL == downloaded)
    #expect(field.data == png)
}

// MARK: - Links

@Test func anAssetIsNotAField() {
    let record = encoder.encode(Poster(title: "Tour", image: png), in: .records)
    #expect(record.allKeys() == ["title"])
}

@Test func anAssetIsSavedOnItsOwnLink() throws {
    let poster = Poster(title: "Tour", image: png)
    let links = encoder.links(for: poster, in: .records)
    #expect(links.count == 1)

    let record = try #require(links.first)
    let link = try decoder.decode(RecordLink.self, from: record)
    #expect(link.source == "Poster.image")
    #expect(link.sourceName == poster.id.uuidString)
    #expect(link.targetName == nil)
    #expect(link.assetID == poster._image.id?.uuidString)
    #expect((record[RecordLink.assetKey] as? CKAsset)?.fileURL == poster.$image)
}

@Test func aDecodedAssetComesFromItsLink() throws {
    let poster = Poster(title: "Tour", image: png)
    let decoded = try decoder.decode(
        Poster.self, from: encoder.encode(poster, in: .records), links: encoder.links(for: poster, in: .records)
    )
    #expect(decoded.$image == poster.$image)
    #expect(decoded.image == png)
    #expect(decoded == poster)
}

@Test func withoutItsLinkAnAssetIsNil() throws {
    let poster = Poster(title: "Tour", image: png)
    let decoded = try decoder.decode(Poster.self, from: encoder.encode(poster, in: .records))
    #expect(decoded.image == nil)
    #expect(decoded.$image == nil)
    #expect(encoder.links(for: decoded, in: .records).isEmpty)
}

@Test func editingOtherFieldsLeavesTheAssetAlone() {
    var poster = Poster(title: "Tour", image: png)
    let links = encoder.links(for: poster, in: .records)
    poster.title = "Encore"
    #expect(encoder.changes(for: poster, from: links).isEmpty)
}

@Test func replacingAnAssetOverwritesItsLink() throws {
    var poster = Poster(title: "Tour", image: png)
    let links = encoder.links(for: poster, in: .records)
    poster.image = Data("second".utf8)

    let changes = encoder.changes(for: poster, from: links)
    #expect(changes.saves.map(\.recordID) == links.map(\.recordID))
    #expect(changes.deletes.isEmpty)
    #expect(try decoder.decode(RecordLink.self, from: changes.saves[0]).assetID == poster._image.id?.uuidString)
}

@Test func clearingAnAssetDropsItsLink() {
    var poster = Poster(title: "Tour", image: png)
    let links = encoder.links(for: poster, in: .records)
    poster.image = nil
    #expect(poster.$image == nil)

    let changes = encoder.changes(for: poster, from: links)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == links.map(\.recordID))
}

// MARK: - Saving

/// A file that couldn't be copied in when it was set, and still can't be at save, fails the
/// save, which writes nothing.
@MainActor
@Test func aFileThatStillCantBeCopiedFailsTheSave() throws {
    let context = try RecordContainer(for: Poster.self, sync: .inMemory).mainContext
    var poster = Poster(title: "Tour", image: nil)
    poster.$image = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    context.insert(poster)
    #expect(throws: (any Error).self) { try context.save() }
    #expect(context.hasChanges)
    #expect(try context.record(id: poster.id) == nil)
}

/// The save copies the file in once it can, so the saved asset reads back.
@MainActor
@Test func aFileThatAppearsBeforeTheSaveIsCopiedIn() throws {
    let container = try RecordContainer(for: Poster.self, sync: .inMemory)
    let context = container.mainContext
    let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    var poster = Poster(title: "Tour", image: nil)
    poster.$image = source
    try png.write(to: source)
    context.insert(poster)
    try context.save()

    let id = try #require(poster._image.id)
    let saved = try #require(try context.record(id: poster.id))
    #expect(saved.$image == container.database.assets.appending(path: "\(id.uuidString).asset"))
    #expect(saved.image == png)
}

/// A saved asset whose file is missing doesn't stop edits to the record's other fields.
@MainActor
@Test func aSavedAssetWithoutItsFileDoesntBlockOtherEdits() throws {
    let container = try RecordContainer(for: Poster.self, sync: .inMemory)
    let context = container.mainContext
    let poster = Poster(title: "Tour", image: png)
    context.insert(poster)
    try context.save()
    let id = try #require(poster._image.id)
    try FileManager.default.removeItem(at: AssetField.url(for: id))
    try FileManager.default.removeItem(at: container.database.assets.appending(path: "\(id.uuidString).asset"))

    var edited = try #require(try context.record(id: poster.id))
    edited.title = "Encore"
    context.insert(edited)
    try context.save()
    #expect(try context.record(id: poster.id)?.title == "Encore")
}

// MARK: - Folders

/// Each container keeps its own copies, so a throwaway container never writes into another's
/// folder, and its folder goes when it does.
@MainActor
@Test func eachContainerKeepsItsOwnAssetFiles() throws {
    var first: RecordContainer? = try RecordContainer(for: Poster.self, sync: .inMemory)
    let second = try RecordContainer(for: Poster.self, sync: .inMemory)
    let poster = Poster(title: "Tour", image: png)
    first?.mainContext.insert(poster)
    try first?.mainContext.save()

    let id = try #require(poster._image.id)
    let name = "\(id.uuidString).asset"
    let folder = try #require(first?.database.assets)
    #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
    #expect(!FileManager.default.fileExists(atPath: second.database.assets.appending(path: name).path))

    first = nil
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

/// A record saved in one container and inserted into another brings its file along.
@MainActor
@Test func aRecordSavedElsewhereBringsItsFile() throws {
    let source = try RecordContainer(for: Poster.self, sync: .inMemory)
    let target = try RecordContainer(for: Poster.self, sync: .inMemory)
    let poster = Poster(title: "Tour", image: png)
    source.mainContext.insert(poster)
    try source.mainContext.save()
    let saved = try #require(try source.mainContext.record(id: poster.id))

    target.mainContext.insert(saved)
    try target.mainContext.save()
    let id = try #require(poster._image.id)
    #expect(FileManager.default.fileExists(atPath: target.database.assets.appending(path: "\(id.uuidString).asset").path))
    #expect(try target.mainContext.record(id: poster.id)?.image == png)
}
