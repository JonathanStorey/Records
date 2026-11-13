import CloudKit
@testable import Records

/// The links to write and delete when a record's links go from `existing` to `now`, worked out the
/// way the store will on save.
struct LinkChanges {
    var saves: [CKRecord]
    var deletes: [CKRecord.ID]

    var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }

    init(_ now: [CKRecord], from existing: [CKRecord]) {
        let decoder = CKRecordDecoder()
        var old: [CKRecord.ID: RecordLink] = [:]
        for record in existing {
            old[record.recordID] = try? decoder.decode(RecordLink.self, from: record)
        }
        saves = now.filter { record in
            guard let previous = old[record.recordID] else { return true }
            return (try? decoder.decode(RecordLink.self, from: record)) != previous
        }
        let kept = Set(now.map(\.recordID))
        deletes = existing.map(\.recordID).filter { !kept.contains($0) }
    }
}

extension CKRecordEncoder {
    /// What saving `record` writes and deletes, given the links it was loaded or last saved with.
    func changes<R: Record>(for record: R, from existing: [CKRecord] = []) -> LinkChanges {
        LinkChanges(links(for: record, in: .records), from: existing)
    }
}

/// The signatures of `record`'s references, computed from their declarations.
func signatures<R: Record>(of record: R) -> [String] {
    record.referenceStates.map { RecordLink.signature(of: $0, in: R.recordType) }
}
