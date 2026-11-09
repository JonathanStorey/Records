import CloudKit

/// Converts a `Record` into a `CKRecord`.
///
/// The record name is the record's `id` as a UUID string, the record type comes from
/// `@Record`, and the zone is supplied by the caller.
public struct CKRecordEncoder: Sendable {
    public init() {}

    public func encode(_ record: some Record, in zone: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id.uuidString, zoneID: zone)
        let ckRecord = CKRecord(recordType: type(of: record).recordType, recordID: recordID)
        record.encodeFields(into: ckRecord)
        return ckRecord
    }
}
