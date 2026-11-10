import CloudKit

/// Converts a `Record` into a `CKRecord`, and its references into link records.
///
/// The record name is the record's `id` as a UUID string, the record type comes from
/// `@Record`, and the zone is supplied by the caller.
public struct CKRecordEncoder: Sendable {
    public init() {}

    /// A new `CKRecord` for `record` in `zone`, with every field. CloudKit treats it as a record it
    /// has never seen.
    public func encode(_ record: some Record, in zone: Zone) -> CKRecord {
        let recordID = CKRecord.ID(recordName: record.id.uuidString, zoneID: zone.zoneID)
        let ckRecord = CKRecord(recordType: type(of: record).recordType, recordID: recordID)
        record.encodeFields(into: ckRecord)
        return ckRecord
    }

    // MARK: Links

    /// Every link `record`'s references point through now, one per target.
    ///
    /// A to-many reference orders its links with order keys. Pass the links the record already
    /// has in `existing`, and each target keeps its key wherever it still sorts in place, so moving
    /// one target changes only that target's link. Comparing the result with `existing` gives the
    /// links to write and the ones to delete. `@Reference(from:)` properties write no links.
    public func links<R: Record>(for record: R, in zone: Zone, existing: [CKRecord] = []) -> [CKRecord] {
        let decoder = CKRecordDecoder()
        var keys: [String: String] = [:]
        for link in existing {
            if let decoded = try? decoder.decode(RecordLink.self, from: link), let order = decoded.order {
                keys[link.recordID.recordName] = order
            }
        }
        return record.referenceStates.flatMap { reference -> [CKRecord] in
            let linkIDs = reference.ids.map {
                RecordLink.id(reference: reference, sourceType: R.recordType, sourceID: record.id, targetID: $0)
            }
            // A sorted reference is ordered by its records' fields, so its links carry no keys.
            let orders: [String?] = reference.isToMany && !reference.isSorted
                ? OrderKey.assign(linkIDs.map { keys[$0.uuidString] })
                : linkIDs.map { _ in nil }
            return zip(reference.ids, orders).map { id, order in
                let target = ReferenceTarget(id: id, order: order)
                let link = RecordLink(reference: reference, sourceType: R.recordType, sourceID: record.id, target: target)
                return encode(link, in: zone)
            }
        }
    }
}
