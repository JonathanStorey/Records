import CloudKit
import Foundation
import Records
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
