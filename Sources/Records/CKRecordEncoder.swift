import CloudKit

/// Why a `Record` could not be written into an existing `CKRecord`.
public enum CKRecordEncodingError: Error, Equatable {
    /// The `CKRecord`'s type is not the `Record`'s `recordType`.
    case recordTypeMismatch(expected: String, found: String)
    /// The `CKRecord`'s name is not the `Record`'s `id`.
    case recordNameMismatch(expected: String, found: String)
}

/// Converts a `Record` into a `CKRecord`.
///
/// The record name is the record's `id` as a UUID string, the record type comes from
/// `@Record`, and the zone is supplied by the caller.
public struct CKRecordEncoder: Sendable {
    public init() {}

    /// A new `CKRecord` for `record` in `zone`. CloudKit treats it as a record it has never seen.
    public func encode(_ record: some Record, in zone: Zone) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id.uuidString, zoneID: zone.zoneID)
        let ckRecord = CKRecord(recordType: type(of: record).recordType, recordID: recordID)
        record.encodeFields(into: ckRecord)
        return ckRecord
    }

    /// Writes `record`'s fields into an existing `CKRecord`, keeping its system fields and change
    /// tag so CloudKit treats the save as an update. Optional properties that are `nil` clear
    /// their field.
    ///
    /// Throws when `ckRecord` has a different record type or a record name other than `record.id`.
    public func encode(_ record: some Record, into ckRecord: CKRecord) throws {
        let expectedType = type(of: record).recordType
        guard ckRecord.recordType == expectedType else {
            throw CKRecordEncodingError.recordTypeMismatch(expected: expectedType, found: ckRecord.recordType)
        }
        let expectedName = record.id.uuidString
        guard ckRecord.recordID.recordName == expectedName else {
            throw CKRecordEncodingError.recordNameMismatch(
                expected: expectedName, found: ckRecord.recordID.recordName
            )
        }
        record.encodeFields(into: ckRecord)
    }
}
