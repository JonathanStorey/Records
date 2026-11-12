import CloudKit
import CoreLocation
import Foundation
import Records
import Testing

@Record
struct Gig: Equatable {
    var id: UUID
    var title: String
    @Location var venue: Coordinate?
    @Location @Encrypted var home: Coordinate?
}

private let hall = Coordinate(latitude: 51.5009, longitude: -0.1773, altitude: 30)

@Test func aCoordinateIsStoredAsAnArchivedCLLocation() throws {
    let gig = Gig(id: UUID(), title: "Proms", venue: hall, home: nil)
    let record = CKRecordEncoder().encode(gig, in: .records)
    let archive = try #require(record.encryptedValues["venue"] as? Data)
    let stored = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CLLocation.self, from: archive))
    #expect(stored.coordinate.latitude == hall.latitude)
    #expect(stored.coordinate.longitude == hall.longitude)
    #expect(stored.altitude == 30)
}

@Test func aLocationStoredAsACLLocationStillReads() throws {
    let record = CKRecordEncoder().encode(Gig(id: UUID(), title: "Proms", venue: nil, home: nil), in: .records)
    record.encryptedValues["venue"] = hall.location
    #expect(try CKRecordDecoder().decode(Gig.self, from: record).venue == hall)
    #expect(try Gig(from: CKRecordDecoder().decode(record, of: Gig.self)).venue == hall)
}

@Test func aCoordinateRoundTrips() throws {
    let gig = Gig(id: UUID(), title: "Proms", venue: hall, home: Coordinate(latitude: 40.7, longitude: -74))
    let decoded = try CKRecordDecoder().decode(Gig.self, from: CKRecordEncoder().encode(gig, in: .records))
    #expect(decoded.venue == hall)
    #expect(decoded.home == Coordinate(latitude: 40.7, longitude: -74))
    #expect(decoded.home?.altitude == nil)
    #expect(decoded == gig)
}

@Test func aLocationIsAlwaysEncrypted() throws {
    let gig = Gig(id: UUID(), title: "Proms", venue: hall, home: hall)
    let record = CKRecordEncoder().encode(gig, in: .records)
    #expect(record["venue"] == nil)
    #expect(record.encryptedValues["venue"] is Data)
    // `@Encrypted` on a location is allowed and changes nothing.
    #expect(record["home"] == nil)
    #expect(record.encryptedValues["home"] is Data)
}

@Test func theFullLocationKeepsEveryDetail() throws {
    var gig = Gig(id: UUID(), title: "Proms", venue: nil, home: nil)
    let taken = Date(timeIntervalSince1970: 1_700_000_000)
    gig.$venue = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: hall.latitude, longitude: hall.longitude),
        altitude: 30, horizontalAccuracy: 5, verticalAccuracy: 3, course: 90, speed: 1.5, timestamp: taken
    )
    #expect(gig.venue == hall)

    let decoded = try CKRecordDecoder().decode(Gig.self, from: CKRecordEncoder().encode(gig, in: .records))
    let location = try #require(decoded.$venue)
    #expect(location.timestamp == taken)
    #expect(location.horizontalAccuracy == 5)
    #expect(location.course == 90)
    #expect(location.speed == 1.5)
}

@Test func settingEitherFormSetsTheLocation() throws {
    let record = CKRecordEncoder().encode(Gig(id: UUID(), title: "Proms", venue: hall, home: nil), in: .records)
    var gig = try CKRecordDecoder().decode(Gig.self, from: record)

    gig.venue = Coordinate(latitude: 48.86, longitude: 2.35)
    #expect(gig.$venue?.coordinate.latitude == 48.86)

    gig.$venue = nil
    #expect(gig.venue == nil)
    #expect(try upload(gig, onto: record).encryptedValues["venue"] == nil)
}
