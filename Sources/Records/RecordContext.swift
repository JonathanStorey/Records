import CloudKit
import Foundation

/// Why a `RecordContext` couldn't read or write a record.
public enum RecordContextError: Error, Equatable, CustomStringConvertible {
    /// The record's type isn't registered with the container.
    case unregisteredType(String)

    public var description: String {
        switch self {
        case .unregisteredType(let type):
            "'\(type)' isn't registered with this container. Pass it, or a type that refers to it, to RecordContainer(for:)."
        }
    }
}

/// Reads and writes records in a container's database.
///
/// The app's main actor uses `container.mainContext`. Changes are staged in the context and
/// reach the database together when `save()` runs, in one transaction:
///
/// ```swift
/// context.insert(album)
/// context.delete(oldAlbum)
/// try context.save()
/// ```
///
/// Saving writes only the fields and links that differ from the saved copy, so a record saved
/// again unchanged writes nothing and stays in sync.
@MainActor
public final class RecordContext {
    /// Every registered type by record type, shared with the container.
    let types: [CKRecord.RecordType: any Record.Type]
    /// The container's database. The context holds it, not the container, so the container can
    /// keep its main context without the two keeping each other alive.
    let database: Database

    /// The zone records are inserted into and deleted from. Set it to switch zones at any time.
    /// Changes already staged keep the zone they were staged in.
    public var zone: Zone = .records

    /// Staged changes by record, in the order they were first staged.
    private var staged: [RecordKey: StagedChange] = [:]
    private var stagedOrder: [RecordKey] = []

    init(container: RecordContainer) {
        types = container.types
        database = container.database
    }

    /// Whether any change is staged and not yet saved, in any zone.
    public var hasChanges: Bool { !staged.isEmpty }

    /// The changes staged in the current `zone`, in the order they were first staged. A record
    /// appears at most once: staging it again replaces its change in place. `save()` writes the
    /// changes of every zone, not only these.
    public var changes: [RecordChange] {
        stagedOrder.filter { $0.zone == zone }.compactMap { staged[$0]?.change }
    }

    // MARK: - Staging

    /// Stages `record` in the current `zone`. Nothing is written until `save()`.
    ///
    /// `record` becomes the record's value: `save()` adds it if it is new, and otherwise writes
    /// the fields and links that differ from the saved copy. Only `record` itself is staged.
    /// Records its references point at are staged by inserting them too.
    public func insert(_ record: some Record) {
        stage(record, .save)
    }

    /// Stages deleting `record` from the current `zone`, with the links it owns. When saved, a
    /// record that never synced is removed outright, and a synced one is kept as a deletion until
    /// the server confirms it.
    public func delete(_ record: some Record) {
        stage(record, .delete)
    }

    /// Writes every staged change in one transaction, then clears them. If any write fails,
    /// nothing is written and the changes stay staged.
    public func save() throws {
        guard hasChanges else { return }
        let changes = stagedOrder.compactMap { key in staged[key].map { (key, $0) } }
        let now = Date().timeIntervalSince1970
        let database = self.database
        try database.transaction {
            for (key, change) in changes {
                let savedLinks = try Self.currentLinks(of: key, in: database)
                switch change.kind {
                case .save:
                    try Self.writeRecord(change.schema, key: key, values: change.values, now: now, in: database)
                    try Self.writeLinks(change.links(Self.orders(of: savedLinks)), of: key, saved: savedLinks, now: now, in: database)
                case .delete:
                    try Self.remove(key, now: now, in: database)
                    try Self.writeLinks([], of: key, saved: savedLinks, now: now, in: database)
                }
            }
        }
        staged.removeAll()
        stagedOrder.removeAll()
    }

    /// Discards every staged change.
    public func rollback() {
        staged.removeAll()
        stagedOrder.removeAll()
    }

    private func stage<R: Record>(_ record: R, _ kind: StagedChange.Kind) {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            preconditionFailure(RecordContextError.unregisteredType(R.recordType).description)
        }
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        let linkKeys = RecordLink.schema.fields.map(\.key)
        let change = StagedChange(
            kind: kind,
            record: record,
            schema: R.schema,
            values: Dictionary(uniqueKeysWithValues: zip(R.schema.fields.map(\.key), record.columnValues())),
            links: { orders in
                Self.links(for: record, orders: orders).map { link in
                    (link.id.uuidString, Dictionary(uniqueKeysWithValues: zip(linkKeys, link.columnValues())))
                }
            }
        )
        if staged.updateValue(change, forKey: key) == nil { stagedOrder.append(key) }
    }

    // MARK: - Writing

    /// Writes a staged record. A new one is inserted with every field. An existing one has the
    /// fields that differ updated, and a deleted one comes back with every field. Before a synced
    /// row first changes, it is copied to its base row, and once it matches its base again the
    /// base is dropped.
    private nonisolated static func writeRecord(
        _ schema: RecordSchema, key: RecordKey, values: [String: SQLValue], now: Double, in database: Database
    ) throws {
        guard let saved = try currentRow(of: key, in: database) else {
            try insertRow(schema.recordType, key: key, fields: values, now: now, in: database)
            return
        }
        let fields = saved["_deleted"] == .integer(1) ? values : values.filter { saved[$0.key] != $0.value }
        guard !fields.isEmpty else { return }
        try keepBase(of: key, in: database)
        try updateRow(key, fields: fields, now: now, in: database)
        try dropBaseIfUnchanged(key, schema: schema, in: database)
    }

    /// Brings the links of `key` in line with `links`. A link that already matches is left alone.
    /// A link that no longer appears is removed.
    private nonisolated static func writeLinks(
        _ links: [(String, [String: SQLValue])], of key: RecordKey, saved: [String: [String: SQLValue]],
        now: Double, in database: Database
    ) throws {
        for (name, values) in links where !matches(saved[name], values) {
            let linkKey = RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone)
            if try currentRow(of: linkKey, in: database) == nil {
                try insertRow(RecordLink.recordType, key: linkKey, fields: values, now: now, in: database)
            } else {
                // A one-to-many target moves to its new source, so its link may belong to another record.
                try keepBase(of: linkKey, in: database)
                try updateRow(linkKey, fields: values, now: now, in: database)
                try dropBaseIfUnchanged(linkKey, schema: RecordLink.schema, in: database)
            }
        }
        let kept = Set(links.map(\.0))
        for name in saved.keys where !kept.contains(name) {
            try remove(RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone), now: now, in: database)
        }
    }

    /// Removes the current row of `key`. A row that never synced is deleted with any base row.
    /// A synced row is marked deleted, so the deletion reaches the server.
    private nonisolated static func remove(_ key: RecordKey, now: Double, in database: Database) throws {
        guard let row = try currentRow(of: key, in: database) else { return }
        let table = database.quoted(key.recordType)
        if row["_systemFields"] == .null {
            try database.run("DELETE FROM \(table) WHERE \(named)", key.values)
        } else {
            try database.run(
                "UPDATE \(table) SET \"_deleted\" = 1, \"_modifiedAt\" = ? WHERE \(named) AND \"_isCurrent\" = 1",
                [.real(now)] + key.values
            )
        }
    }

    private nonisolated static func insertRow(
        _ recordType: CKRecord.RecordType, key: RecordKey, fields: [String: SQLValue], now: Double, in database: Database
    ) throws {
        let names = Array(fields.keys)
        let columns = ["_name", "_isCurrent", "_zoneName", "_zoneOwner", "_createdAt", "_modifiedAt"] + names
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try database.run(
            "INSERT INTO \(database.quoted(recordType)) (\(columns.map(database.quoted).joined(separator: ", "))) VALUES (\(placeholders))",
            [.text(key.name), .integer(1), .text(key.zone.name), .text(key.zone.ownerName), .real(now), .real(now)]
                + names.map { fields[$0]! }
        )
    }

    private nonisolated static func updateRow(_ key: RecordKey, fields: [String: SQLValue], now: Double, in database: Database) throws {
        let names = Array(fields.keys)
        let assignments = ["\"_deleted\" = 0", "\"_modifiedAt\" = ?"] + names.map { "\(database.quoted($0)) = ?" }
        try database.run(
            "UPDATE \(database.quoted(key.recordType)) SET \(assignments.joined(separator: ", ")) WHERE \(named) AND \"_isCurrent\" = 1",
            [.real(now)] + names.map { fields[$0]! } + key.values
        )
    }

    /// Copies the current row of `key` to its base row when the current row has synced and no
    /// base row exists. The base row holds the server's last known values until the next upload.
    private nonisolated static func keepBase(of key: RecordKey, in database: Database) throws {
        let table = database.quoted(key.recordType)
        let columns = try database.columnNames(key.recordType).map(database.quoted)
        let selected = columns.map { $0 == "\"_isCurrent\"" ? "0" : $0 }
        try database.run(
            """
            INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ", "))) \
            SELECT \(selected.joined(separator: ", ")) FROM \(table) \
            WHERE \(named) AND "_isCurrent" = 1 AND "_systemFields" IS NOT NULL
            """,
            key.values
        )
    }

    /// Drops the base row of `key` when the current row's fields match it again, so an edit that
    /// is undone leaves the record with nothing to upload.
    private nonisolated static func dropBaseIfUnchanged(_ key: RecordKey, schema: RecordSchema, in database: Database) throws {
        let rows = try database.rows("SELECT * FROM \(database.quoted(key.recordType)) WHERE \(named)", key.values)
        guard let current = rows.first(where: { $0["_isCurrent"] == .integer(1) }),
              let base = rows.first(where: { $0["_isCurrent"] == .integer(0) }),
              current["_deleted"] == .integer(0),
              schema.fields.allSatisfy({ current[$0.key] == base[$0.key] })
        else { return }
        try database.run(
            "DELETE FROM \(database.quoted(key.recordType)) WHERE \(named) AND \"_isCurrent\" = 0", key.values
        )
    }

    // MARK: - Reading

    /// Matches one record's rows by zone and name.
    private nonisolated static let named = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_name\" = ?"

    /// The current row of `key`, or `nil` when there is none.
    private nonisolated static func currentRow(of key: RecordKey, in database: Database) throws -> [String: SQLValue]? {
        try database.rows(
            "SELECT * FROM \(database.quoted(key.recordType)) WHERE \(named) AND \"_isCurrent\" = 1", key.values
        ).first
    }

    /// The current, undeleted links `key`'s record owns, by link name.
    private nonisolated static func currentLinks(of key: RecordKey, in database: Database) throws -> [String: [String: SQLValue]] {
        let prefix = key.recordType + "."
        let rows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "sourceName" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND substr("source", 1, ?) = ?
            """,
            key.values + [.integer(Int64(prefix.count)), .text(prefix)]
        )
        return Dictionary(
            rows.compactMap { row in
                guard case .text(let name) = row["_name"] else { return nil }
                return (name, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Whether `row` exists and holds every value in `values`.
    private nonisolated static func matches(_ row: [String: SQLValue]?, _ values: [String: SQLValue]) -> Bool {
        guard let row else { return false }
        return values.allSatisfy { row[$0.key] == $0.value }
    }

    /// The saved order key of each link target in `links`, by `source|targetName`, so a target
    /// that keeps its place keeps its key.
    private nonisolated static func orders(of links: [String: [String: SQLValue]]) -> [String: String] {
        Dictionary(
            links.values.compactMap { row -> (String, String)? in
                guard case .text(let source) = row["source"], case .text(let target) = row["targetName"],
                      case .text(let order) = row["order"] else { return nil }
                return (source + "|" + target, order)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Links

    /// A link for each target of each reference that writes links, in order, and one for each
    /// `@Asset` that holds data. `orders` holds the saved order key of each target by
    /// `source|targetName`, so a target that keeps its place keeps its key.
    nonisolated static func links<R: Record>(for record: R, orders: [String: String] = [:]) -> [RecordLink] {
        let references = record.referenceStates.flatMap { reference -> [RecordLink] in
            let source = RecordLink.source(type: R.recordType, property: reference.property)
            // A sorted reference is ordered by its records' fields, so its links carry no keys.
            let keys: [String?] = reference.isToMany && !reference.isSorted
                ? OrderKey.assign(reference.ids.map { orders[source + "|" + $0.uuidString] })
                : reference.ids.map { _ in nil }
            return zip(reference.ids, keys).map { id, order in
                RecordLink(reference: reference, sourceType: R.recordType, sourceID: record.id, target: ReferenceTarget(id: id, order: order))
            }
        }
        let assets = record.assetStates.compactMap { asset in
            asset.id.map { RecordLink(asset: asset, assetID: $0, sourceType: R.recordType, sourceID: record.id) }
        }
        return references + assets
    }
}

/// One record's identity in the database: its type, name, and zone.
struct RecordKey: Hashable, Sendable {
    let recordType: CKRecord.RecordType
    let name: String
    let zone: Zone

    /// The values for `RecordContext.named`, in order.
    var values: [SQLValue] { [.text(zone.name), .text(zone.ownerName), .text(name)] }
}

/// A change staged in a `RecordContext`, waiting for `save()`.
public enum RecordChange {
    /// The record is saved: added if new, or replacing the saved copy.
    case insert(any Record)
    /// The record is deleted with the links it owns.
    case delete(any Record)

    /// The record's ID.
    public var id: UUID { record.id }

    /// The record the change carries.
    public var record: any Record {
        switch self {
        case .insert(let record), .delete(let record): record
        }
    }
}

/// A change staged in a context and written by `save()`.
struct StagedChange {
    enum Kind {
        /// Write the record's values and bring its links in line.
        case save
        /// Remove the record and its links.
        case delete
    }

    let kind: Kind
    let record: any Record
    let schema: RecordSchema
    /// Every field's column value, by field key.
    let values: [String: SQLValue]
    /// The record's links by name, given the saved order key of each target by
    /// `source|targetName`.
    let links: ([String: String]) -> [(String, [String: SQLValue])]

    /// The public form of this change.
    var change: RecordChange {
        switch kind {
        case .save: .insert(record)
        case .delete: .delete(record)
        }
    }
}
