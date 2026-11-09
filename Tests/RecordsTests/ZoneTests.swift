import CloudKit
import Testing
@testable import Records

@Test(arguments: ["Notes", "Records", "my-zone", "Zone_1"])
func customZoneNamesAreAllowed(name: String) {
    #expect(Zone.isAllowed(name))
}

@Test(arguments: ["", "_defaultZone", CKRecordZone.ID.defaultZoneName, "_private"])
func defaultAndReservedZoneNamesAreRejected(name: String) {
    #expect(!Zone.isAllowed(name))
}
