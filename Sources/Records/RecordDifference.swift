import CloudKit
import Foundation

/// One record's identity in the database: its type, name, and zone.
struct RecordKey: Hashable, Sendable {
    let recordType: CKRecord.RecordType
    let name: String
    let zone: Zone

    /// The values for `Database.named`, in order.
    var values: [SQLValue] { [.text(zone.name), .text(zone.ownerName), .text(name)] }
}

/// One pending edit to a record in a `RecordContext`, waiting for `save()`.
///
/// Each `@Recordable` that edits a record makes its own, and so does each direct `insert` or
/// `delete`. Only its `id` and `Change` are public.
public struct RecordDifference: Identifiable {
    /// What is to happen to a record when its context saves.
    public enum Change: Hashable, Sendable, Identifiable {
        /// The record is added.
        case insert(UUID)
        /// The record is updated where it was edited.
        case update(UUID)
        /// The record is deleted with the links it owns.
        case delete(UUID)

        /// The record's ID.
        public var id: UUID {
            switch self {
            case .insert(let id), .update(let id), .delete(let id): id
            }
        }
    }

    /// The edit's ID: a `@Recordable`'s own, or a new one for each direct `insert` or `delete`.
    public let id: UUID
    /// The zone the record is in.
    let zone: Zone
    /// The record the edit started from, or `nil` for a new record. `save()` writes only what
    /// `edit` changed from it.
    var base: (any Record)?
    /// The record as edited, or `nil` for a delete.
    var edit: (any Record)?
    /// When the record was last edited. Saves write the oldest edit first.
    var modified: Date

    /// What saving does: an insert without a base, a delete without an edit, and otherwise an
    /// update.
    public var change: Change {
        guard edit != nil else { return .delete(recordID) }
        return base == nil ? .insert(recordID) : .update(recordID)
    }

    /// Moves the edit onto `newBase`, the record as saved elsewhere since: each field and link
    /// the edit changed from `base` is laid over `newBase`. When `newBase` is `nil`, the record
    /// was deleted elsewhere, and an edit brings it back as an insert.
    mutating func rebase(onto newBase: (any Record)?) {
        if let edit, let base, let newBase { self.edit = Self.merged(edit, over: newBase, original: base) }
        base = newBase
    }

    /// `record` with this edit laid over it, as `save()` would leave it: `nil` for a delete,
    /// the edit whole for an insert or when `record` is `nil`, and otherwise the fields and
    /// links the edit changed from `base` laid over `record`.
    func laid(over record: (any Record)?) -> (any Record)? {
        guard let edit else { return nil }
        guard let base, let record else { return edit }
        return Self.merged(edit, over: record, original: base)
    }

    /// Whether `a` is saved before `b`: the older edit first, and by `id` when both are as old.
    static func isOlder(_ a: RecordDifference, _ b: RecordDifference) -> Bool {
        a.modified != b.modified ? a.modified < b.modified : a.id.uuidString < b.id.uuidString
    }
}

// What `save()` and reads need, worked out from the edit and the base when asked.
extension RecordDifference {
    var isDelete: Bool { edit == nil }

    /// The edit, or the base for a delete. A difference always has one of them.
    var record: any Record {
        guard let record = edit ?? base else { preconditionFailure("A difference has no record") }
        return record
    }

    /// The ID of the record edited.
    var recordID: UUID { record.uuid }

    /// Where the record is kept: its type, its ID and its zone.
    var key: RecordKey {
        RecordKey(recordType: type(of: record).recordType, name: recordID.uuidString, zone: zone)
    }

    var schema: RecordSchema { type(of: record).schema }

    /// Every field's column value, by field key.
    var values: [String: SQLValue] { record.columnValues() }

    /// `base`'s column values, by field key.
    var originalValues: [String: SQLValue]? { base?.columnValues() }

    /// The edit's links by name.
    var links: [(String, [String: SQLValue])] { Self.linkRows(of: record) }

    /// `base`'s links by name, or `nil` when there is no base.
    var originalLinks: [(String, [String: SQLValue])]? { base.map { Self.linkRows(of: $0) } }

    /// `draft` laid over `saved`: each field and owned link the draft changed from `original`
    /// replaces the saved one. The `from:` sides, which the record doesn't own, come from
    /// `saved`. A record of another type, or one that can't be read back, reads as the draft.
    fileprivate static func merged<R: Record>(_ draft: R, over saved: any Record, original: any Record) -> any Record {
        guard let saved = saved as? R, let original = original as? R else { return draft }
        var row = saved.columnValues()
        let originalValues = original.columnValues()
        for (field, value) in draft.columnValues() where originalValues[field] != value {
            row[field] = value
        }

        var links = Dictionary(linkRows(of: saved), uniquingKeysWith: { first, _ in first })
        let originalLinks = Dictionary(linkRows(of: original), uniquingKeysWith: { first, _ in first })
        let draftLinks = linkRows(of: draft)
        let kept = Set(draftLinks.map(\.0))
        for name in originalLinks.keys where !kept.contains(name) {
            links[name] = nil
        }
        for (name, values) in draftLinks where !RecordContext.matches(originalLinks[name], values) {
            links[name] = (links[name] ?? [:]).merging(values) { $1 }
        }

        row["_name"] = .text(draft.id.uuidString)
        var graph = RecordGraph()
        for (name, row) in links {
            graph.addLink(row, name: name)
        }
        guard var merged = try? R(from: RecordRow(row)) else { return draft }
        do {
            try graph.load(&merged, depth: 0)
        } catch {
            return draft
        }
        let fromSides = Set(R.schema.references.filter(\.isFrom).map(\.property))
        for (keyPath, property) in R.keyPaths where fromSides.contains(property) {
            // A `from:` side holds only IDs, as an `Owner.ID?` or an `[Owner.ID]`.
            let value = saved[keyPath: keyPath]
            let ids = (value as? [any RawRepresentable<UUID>])?.map { $0.rawValue } ?? (value as? any RawRepresentable<UUID>).map { [$0.rawValue] } ?? []
            try? merged.loadReference(property, to: ids, from: graph, depth: 0)
        }
        return merged
    }

    private static func linkRows<R: Record>(of record: R) -> [(String, [String: SQLValue])] {
        record.links().map { link in
            (link.id.uuidString, link.columnValues())
        }
    }
}

