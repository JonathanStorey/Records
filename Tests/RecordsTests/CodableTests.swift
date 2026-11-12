import Foundation
import Testing
@testable import Records

@Record
struct Novel: Codable {
    var id: UUID
    var title: String
    var subtitle: String?
    var tags: [String]
    @Renamed("released") var year: Int
    @Encrypted var note: String?
    @Asset var cover: Data?
    @Location var shop: Coordinate?
    @Timestamped(.created) var createdAt: Date?
    @Reference var sequel: Novel?
    @Reference var writers: [Writer]
    @Reference var editor: Writer?
}

@Record
struct Writer: Codable, Equatable {
    var id: UUID
    var name: String
    @Reference(from: \Novel.writers) var bookIDs: [UUID]
}

/// A record that writes its own `encode(to:)`, which `@Record` keeps.
@Record
struct Stamp: Codable {
    var id: UUID
    var label: String

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

private let ada = Writer(id: UUID(), name: "Ada", bookIDs: [])
private let grace = Writer(id: UUID(), name: "Grace", bookIDs: [])
private let sequel = Novel(
    id: UUID(), title: "Part Two", subtitle: nil, tags: [], year: 2025, note: nil,
    cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
)

private func makeBook() -> Novel {
    Novel(
        id: UUID(), title: "Notes", subtitle: "On engines", tags: ["math", "machines"], year: 1843,
        note: "draft", cover: Data("cover".utf8), shop: Coordinate(latitude: 51.5, longitude: -0.12),
        sequel: sequel, writers: [ada, grace], editor: ada
    )
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

@Test func codableKeepsEveryField() throws {
    let book = makeBook()
    let decoded = try roundTrip(book)
    #expect(decoded.id == book.id)
    #expect(decoded.title == "Notes")
    #expect(decoded.subtitle == "On engines")
    #expect(decoded.tags == ["math", "machines"])
    #expect(decoded.year == 1843)
    #expect(decoded.note == "draft")
    #expect(decoded.shop == book.shop)
}

@Test func codableUsesSwiftNamesAndSkipsTimestamps() throws {
    let json = try jsonObject(makeBook())
    #expect(Set(json.keys) == [
        "id", "title", "subtitle", "tags", "year", "note", "cover", "shop", "sequel", "writers", "editor",
    ])
}

@Test func codableLeavesOutNilValues() throws {
    let json = try jsonObject(sequel)
    #expect(Set(json.keys) == ["id", "title", "tags", "year", "writers"])
    #expect((json["writers"] as? [Any])?.isEmpty == true)

    let decoded = try roundTrip(sequel)
    #expect(decoded.subtitle == nil && decoded.note == nil && decoded.cover == nil && decoded.shop == nil)
    #expect(decoded.referenceID(at: \.sequel) == nil && decoded.referenceIDs(at: \.writers).isEmpty && decoded.referenceID(at: \.editor) == nil)
}

@Test func referencesDecodeAsIDs() throws {
    let book = makeBook()
    let decoded = try roundTrip(book)
    #expect(decoded.referenceID(at: \.sequel) == sequel.id)
    #expect(decoded.sequel == nil)
    #expect(decoded.referenceIDs(at: \.writers) == [ada.id, grace.id])
    #expect(decoded.writers.isEmpty)
    #expect(decoded.referenceID(at: \.editor) == ada.id)

    let json = try jsonObject(book)
    #expect(json["sequel"] as? String == sequel.id.uuidString)
    #expect(json["writers"] as? [String] == [ada.id.uuidString, grace.id.uuidString])
}

@Test func fromSideEncodesItsIDs() throws {
    let bookID = UUID()
    let writer = Writer(id: UUID(), name: "Ada", bookIDs: [bookID])
    #expect(try roundTrip(writer) == writer)
    #expect(try roundTrip(writer).bookIDs == [bookID])
}

@Test func assetsEncodeTheirIDAndFindTheirFile() throws {
    let book = makeBook()
    let json = try jsonObject(book)
    #expect(json["cover"] as? String == book._cover.id?.uuidString)

    let decoded = try roundTrip(book)
    #expect(decoded._cover.id == book._cover.id)
    #expect(decoded.cover == Data("cover".utf8))
    #expect(decoded.$cover == book.$cover)
}

@Test func aWrittenEncodeIsKept() throws {
    let data = try JSONEncoder().encode(Stamp(id: UUID(), label: "first"))
    #expect(String(decoding: data, as: UTF8.self) == "\"first\"")
}
