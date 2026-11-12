import CloudKit
import Foundation
@testable import Records
import Testing

enum Mood: String, Codable {
    case calm, energetic
}

enum Rating: Int {
    case one = 1, two, three
}

struct Address: Codable, Equatable {
    var street: String
    var city: String
}

@Record
struct Venue: Equatable {
    var id: UUID
    @Renamed("title") var name: String
    var mood: Mood
    var rating: Rating?
    var address: Address
    var previous: Address?
    var moods: [Mood]
}

private func venue() -> Venue {
    Venue(
        id: UUID(), name: "Hall", mood: .energetic, rating: .three,
        address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm, .energetic]
    )
}

@Test func rawValueEnumsAreStoredAsTheirRawValue() {
    let record = CKRecordEncoder().encode(venue(), in: .records)
    #expect(record["mood"] as? String == "energetic")
    #expect(record["rating"] as? Int == 3)
}

@Test func codableValuesAreStoredAsJSON() throws {
    let record = CKRecordEncoder().encode(venue(), in: .records)
    let data = try #require(record["address"] as? Data)
    #expect(try JSONDecoder().decode(Address.self, from: data) == Address(street: "1 Main", city: "Springfield"))
    #expect(record["moods"] is Data)
    #expect(record["previous"] == nil)
}

@Test func renamedFieldsUseTheirOriginalName() {
    let record = CKRecordEncoder().encode(venue(), in: .records)
    #expect(record["title"] as? String == "Hall")
    #expect(record["name"] == nil)
}

@Test func mappedFieldsRoundTrip() throws {
    let original = venue()
    let decoded = try CKRecordDecoder().decode(Venue.self, from: CKRecordEncoder().encode(original, in: .records))
    #expect(decoded == original)
}

@Test func stringsStayStringsEvenThoughTheyAreCodable() {
    let record = CKRecordEncoder().encode(venue(), in: .records)
    #expect(record["title"] is String)
}

@Test func anUnknownRawValueIsATypeMismatch() {
    let record = CKRecordEncoder().encode(venue(), in: .records)
    record["mood"] = "sleepy"
    #expect(throws: CKRecordDecodingError.typeMismatch(field: "mood")) {
        try CKRecordDecoder().decode(Venue.self, from: record)
    }
}

// MARK: - Values stored as strings

struct SeatCode: RawRepresentable, Codable, Equatable {
    var rawValue: UUID
}

struct Version: LosslessStringConvertible, Codable, Equatable {
    var major: Int
    var minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ description: String) {
        let parts = description.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(major: parts[0], minor: parts[1])
    }

    var description: String { "\(major).\(minor)" }
}

@Record
struct Ticket: Equatable {
    var id: UUID
    var holder: UUID
    var seat: SeatCode?
    var version: Version
    var link: URL?
    var count: Int
}

func ticket(holder: UUID = UUID()) -> Ticket {
    Ticket(
        id: UUID(), holder: holder, seat: SeatCode(rawValue: UUID()), version: Version(major: 2, minor: 1),
        link: URL(string: "https://example.com/a?b=c"), count: 3
    )
}

@Test func stringConvertibleValuesAreStoredAsStrings() {
    let original = ticket()
    let record = CKRecordEncoder().encode(original, in: .records)
    #expect(record["holder"] as? String == original.holder.uuidString)
    #expect(record["seat"] as? String == original.seat?.rawValue.uuidString)
    #expect(record["version"] as? String == "2.1")
    #expect(record["link"] as? String == "https://example.com/a?b=c")
    #expect(record["count"] as? Int == 3)
}

@Test func anUnreadableStringIsATypeMismatch() {
    let record = CKRecordEncoder().encode(ticket(), in: .records)
    record["holder"] = "not a uuid"
    #expect(throws: CKRecordDecodingError.typeMismatch(field: "holder")) {
        try CKRecordDecoder().decode(Ticket.self, from: record)
    }
}

@MainActor
@Test func fetchingFiltersOnValuesStoredAsStrings() throws {
    let holder = UUID()
    let mine = ticket(holder: holder)
    let context = try RecordContainer(for: [Ticket.self], url: nil).mainContext
    context.insert(mine)
    context.insert(ticket())
    try context.save()
    let seat = mine.seat
    let byHolder = try context.fetch(RecordDescriptor(predicate: #Predicate<Ticket> { $0.holder == holder }))
    let bySeat = try context.fetch(RecordDescriptor(predicate: #Predicate<Ticket> { $0.seat == seat }))
    #expect(byHolder.map(\.id) == [mine.id])
    #expect(bySeat.map(\.id) == [mine.id])
}

// MARK: - Stable JSON

struct Shape: Codable, Equatable {
    var zoom: Double
    var counts: [String: Int]
    var note: String?
    var inner: Inner

    struct Inner: Codable, Equatable {
        var visible: Bool
        var label: String
    }
}

private func json(_ shape: Shape) throws -> String {
    let data = try #require(FieldCoding(Shape.self).value(shape) as? Data)
    return String(decoding: data, as: UTF8.self)
}

/// The store finds changes by comparing stored bytes, so equal values must encode identically.
@Test func codableFieldsEncodeToFixedBytes() throws {
    let shape = Shape(zoom: 1.5, counts: ["b": 2, "a": 1, "c": 3], note: nil, inner: .init(visible: true, label: "x/y"))
    #expect(try json(shape) == #"{"counts":{"a":1,"b":2,"c":3},"inner":{"label":"x\/y","visible":true},"zoom":1.5}"#)
}

@Test func equalCodableValuesEncodeToEqualBytes() throws {
    let keys = (0..<50).map { "key\($0)" }
    let first = try json(Shape(zoom: 0.1, counts: Dictionary(uniqueKeysWithValues: keys.map { ($0, 1) }), note: "n", inner: .init(visible: false, label: "")))
    for _ in 0..<20 {
        var counts: [String: Int] = [:]
        for key in keys.shuffled() { counts[key] = 1 }
        #expect(try json(Shape(zoom: 0.1, counts: counts, note: "n", inner: .init(visible: false, label: ""))) == first)
    }
}

@Test func nilAndValueEncodeDifferently() throws {
    let empty = Shape(zoom: 0, counts: [:], note: nil, inner: .init(visible: false, label: ""))
    var noted = empty
    noted.note = ""
    #expect(try json(empty) != json(noted))
    noted.note = nil
    #expect(try json(empty) == json(noted))
}
