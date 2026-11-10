import CloudKit
import Foundation
import Records
import Testing

@Record
struct Poster: Equatable {
    var id: UUID
    var title: String
    @Asset var image: Data?
}

private let png = Data("not really a png".utf8)

@Test func settingAnAssetWritesAFile() throws {
    let poster = Poster(id: UUID(), title: "Tour", image: png)
    let url = try #require(poster.$image)
    #expect(url.pathExtension == "asset")
    #expect(url.deletingLastPathComponent().standardizedFileURL == AssetField.directory.standardizedFileURL)
    #expect(try Data(contentsOf: url) == png)
    #expect(poster.image == png)
}

@Test func eachNewValueGetsItsOwnFile() throws {
    var poster = Poster(id: UUID(), title: "Tour", image: png)
    let first = try #require(poster.$image)
    poster.image = Data("second".utf8)
    let second = try #require(poster.$image)
    #expect(first != second)
    #expect(poster.image == Data("second".utf8))
}

@Test func anAssetIsSavedAsACKAsset() throws {
    let poster = Poster(id: UUID(), title: "Tour", image: png)
    let record = CKRecordEncoder().encode(poster, in: .records)
    let asset = try #require(record["image"] as? CKAsset)
    #expect(asset.fileURL == poster.$image)
}

@Test func aDecodedAssetReadsTheDownloadedFile() throws {
    let poster = Poster(id: UUID(), title: "Tour", image: png)
    let decoded = try CKRecordDecoder().decode(Poster.self, from: CKRecordEncoder().encode(poster, in: .records))
    #expect(decoded.$image == poster.$image)
    #expect(decoded.image == png)
    #expect(decoded == poster)
}

@Test func clearingAnAssetClearsTheField() throws {
    let record = CKRecordEncoder().encode(Poster(id: UUID(), title: "Tour", image: png), in: .records)
    var poster = try CKRecordDecoder().decode(Poster.self, from: record)
    poster.image = nil
    #expect(poster.$image == nil)

    try CKRecordEncoder().encode(poster, into: record)
    #expect(record["image"] == nil)
}

@Test func aMissingAssetIsNil() throws {
    let poster = Poster(id: UUID(), title: "Tour", image: nil)
    let decoded = try CKRecordDecoder().decode(Poster.self, from: CKRecordEncoder().encode(poster, in: .records))
    #expect(decoded.image == nil)
    #expect(decoded.$image == nil)
}
