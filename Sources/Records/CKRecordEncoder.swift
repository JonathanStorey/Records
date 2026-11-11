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

    /// The `CKRecord` to upload for `R`'s database row `row` in `zone`, with every field. A row
    /// that has synced starts from the record the server last returned, so the upload carries
    /// its change tag and the server treats it as an update. Otherwise it is a new record.
    public func encode<R: Record>(_ row: RecordRow, of type: R.Type, in zone: Zone) -> CKRecord {
        guard case .text(let name) = row.values["_name"] else {
            preconditionFailure("A RecordRow always holds its record's name")
        }
        let base = row.serverRecord(recordType: R.recordType, name: name, zone: zone)
        return R.schema.record(from: row.values, name: name, zone: zone, onto: base)
    }

    // MARK: Links

    /// Every link `record`'s references point through now, one per target.
    ///
    /// A to-many reference orders its links with order keys. Pass the links the record already
    /// has in `existing`, and each target keeps its key wherever it still sorts in place, so moving
    /// one target changes only that target's link. Comparing the result with `existing` gives the
    /// links to write and the ones to delete. `@Reference(from:)` properties write no links.
    ///
    /// Each `@Asset` that holds data adds a link that carries the asset.
    public func links(for record: some Record, in zone: Zone, existing: [CKRecord] = []) -> [CKRecord] {
        let decoder = CKRecordDecoder()
        var orders: [String: String] = [:]
        for link in existing {
            if let link = try? decoder.decode(RecordLink.self, from: link), let order = link.order {
                orders[link.orderKey] = order
            }
        }
        return record.links(orders: orders).map { link in
            let linkRecord = encode(link, in: zone)
            if link.assetID != nil {
                let asset = record.assetStates.first { $0.property == link.sourceProperty }
                linkRecord[RecordLink.assetKey] = asset?.fileURL.map(CKAsset.init(fileURL:))
            }
            return linkRecord
        }
    }
}
