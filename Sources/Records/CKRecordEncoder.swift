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

    // MARK: Links

    /// The links to save for `record`'s references that changed since it was loaded or saved.
    ///
    /// A to-one reference that now points somewhere writes its link, which overwrites the link
    /// it had before. A to-many reference writes a link for each added target and each target
    /// whose order key changed, so moving one target rewrites only that target's link.
    ///
    /// Save these along with the record, then call `markReferencesSaved()` on it.
    public func linksToSave<R: Record>(for record: R, in zone: Zone) -> [CKRecord] {
        record.referenceStates.flatMap { reference -> [CKRecord] in
            guard reference.hasChanges else { return [] }
            let unchanged = Set(reference.loaded)
            return reference.targets
                .filter { reference.isToMany ? !unchanged.contains($0) : true }
                .map { target in
                    let link = RecordLink(reference: reference, sourceType: R.recordType, sourceID: record.id, target: target)
                    return encode(link, in: zone)
                }
        }
    }

    /// The IDs of links to delete for `record`'s references: a to-one reference that was
    /// cleared, and each target removed from a to-many reference.
    public func linkIDsToDelete<R: Record>(for record: R, in zone: Zone) -> [CKRecord.ID] {
        record.referenceStates.flatMap { reference -> [CKRecord.ID] in
            guard reference.hasChanges else { return [] }
            let current = Set(reference.targets.map(\.id))
            let removed = reference.isToMany
                ? reference.loaded.filter { !current.contains($0.id) }
                : (current.isEmpty ? Array(reference.loaded.prefix(1)) : [])
            return removed.map { target in
                let id = RecordLink.id(reference: reference, sourceType: R.recordType, sourceID: record.id, targetID: target.id)
                return CKRecord.ID(recordName: id.uuidString, zoneID: zone.zoneID)
            }
        }
    }
}
