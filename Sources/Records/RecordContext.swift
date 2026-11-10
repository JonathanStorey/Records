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
                try Self.write(change, key: key, now: now, in: database)
            }
            try insertNewTargets(of: changes, now: now, in: database)
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
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        if staged.updateValue(Self.change(for: record, kind), forKey: key) == nil { stagedOrder.append(key) }
    }

    /// The change that saves or deletes `record`.
    private static func change<R: Record>(for record: R, _ kind: StagedChange.Kind) -> StagedChange {
        let linkKeys = RecordLink.schema.fields.map(\.key)
        return StagedChange(
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
    }

    /// Inserts the loaded targets of the saved records that exist nowhere yet: not saved in the
    /// zone, deleted or not, and not staged. A target that exists is never written, so a stale
    /// copy can't overwrite it. New targets' own new targets are inserted too.
    private func insertNewTargets(of changes: [(RecordKey, StagedChange)], now: Double, in database: Database) throws {
        var visited = Set(changes.map(\.0))
        var queue = changes.compactMap { key, change in change.kind == .save ? (key.zone, change.record) : nil }
        while !queue.isEmpty {
            let (zone, record) = queue.removeFirst()
            for target in record.loadedTargets {
                let key = RecordKey(recordType: type(of: target).recordType, name: target.id.uuidString, zone: zone)
                guard visited.insert(key).inserted,
                      try Self.currentRow(of: key, in: database) == nil
                else { continue }
                try Self.write(Self.change(for: target, .save), key: key, now: now, in: database)
                queue.append((zone, target))
            }
        }
    }

    /// Writes one change: the record's row and its links.
    private nonisolated static func write(_ change: StagedChange, key: RecordKey, now: Double, in database: Database) throws {
        let savedLinks = try currentLinks(of: key, in: database)
        switch change.kind {
        case .save:
            try writeRecord(change.schema, key: key, values: change.values, now: now, in: database)
            try writeLinks(change.links(orders(of: savedLinks)), of: key, saved: savedLinks, now: now, in: database)
        case .delete:
            try remove(key, now: now, in: database)
            try writeLinks([], of: key, saved: savedLinks, now: now, in: database)
        }
    }

    // MARK: - Reading

    /// The `R` with `id` in the current `zone`, or `nil` when there is none. A staged change
    /// comes first: a staged insert returns the staged record, and a staged delete returns `nil`.
    ///
    /// References hold their targets' IDs. Load the targets themselves with `record(id:for:)`.
    public func record<R: Record>(id: UUID, for type: R.Type = R.self) throws -> R? {
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        if let change = staged[key] {
            return change.kind == .delete ? nil : change.record as? R
        }
        return try Self.load(R.self, key: key, in: database)
    }

    /// The record with `id` in the current `zone`, whatever its type, or `nil` when there is none.
    /// A staged change comes first, as in `record(id:for:)`. Finding the type takes one indexed
    /// query across every table.
    public func record(id: UUID) throws -> (any Record)? {
        let name = id.uuidString
        if let key = stagedOrder.first(where: { $0.name == name && $0.zone == zone && $0.recordType != RecordLink.recordType }),
           let change = staged[key] {
            return change.kind == .delete ? nil : change.record
        }
        let lookup = recordTypeLookup
        let values = Array(repeating: RecordKey(recordType: "", name: name, zone: zone).values, count: lookup.tables).flatMap { $0 }
        guard case .text(let recordType) = try database.rows(lookup.sql, values).first?["type"],
              let type = types[recordType]
        else { return nil }
        return try Self.load(type, key: RecordKey(recordType: recordType, name: name, zone: zone), in: database)
    }

    /// The records of `R` in the current `zone` that match `descriptor`, sorted and limited as it
    /// says. Staged changes count: a staged insert is included as staged, and a staged delete
    /// leaves its record out. References hold their targets' IDs.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        checkRegistered(R.self)
        var records = try Self.loadAll(R.self, zone: zone, in: database)

        // Staged changes in this zone replace or remove the saved records they name.
        let stagedHere = stagedOrder.filter { $0.zone == zone && $0.recordType == R.recordType }
        if !stagedHere.isEmpty {
            let names = Set(stagedHere.map(\.name))
            records.removeAll { names.contains($0.id.uuidString) }
            records += stagedHere.compactMap { key in
                guard let change = staged[key], change.kind == .save else { return nil }
                return change.record as? R
            }
        }

        if let predicate = descriptor.predicate {
            records = try records.filter { try predicate.evaluate($0) }
        }
        if !descriptor.sortBy.isEmpty {
            records.sort(using: descriptor.sortBy)
        }
        let start = min(max(descriptor.fetchOffset ?? 0, 0), records.count)
        let end = descriptor.fetchLimit.map { min(start + max($0, 0), records.count) } ?? records.count
        return Array(records[start..<end])
    }

    /// How many records `fetch(descriptor)` would return.
    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        try fetch(descriptor).count
    }

    /// Every saved, undeleted `R` in `zone`, with references holding IDs. One query reads the
    /// rows and one reads every link they own or are the target of.
    private nonisolated static func loadAll<R: Record>(_ type: R.Type, zone: Zone, in database: Database) throws -> [R] {
        let table = database.quoted(R.recordType)
        let current = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        let zoneValues: [SQLValue] = [.text(zone.name), .text(zone.ownerName)]
        let rows = try database.rows("SELECT * FROM \(table) WHERE \(current)", zoneValues)
        guard !rows.isEmpty else { return [] }

        let names = "SELECT \"_name\" FROM \(table) WHERE \(current)"
        let linkRows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) WHERE \(current) \
            AND ("sourceName" IN (\(names)) OR "targetName" IN (\(names)))
            """,
            zoneValues + zoneValues + zoneValues
        )
        var linksByName: [String: [CKRecord]] = [:]
        for row in linkRows {
            guard case .text(let name) = row["_name"] else { continue }
            let link = RecordLink.schema.record(from: row, name: name, zone: zone)
            if case .text(let source) = row["sourceName"] { linksByName[source, default: []].append(link) }
            if case .text(let target) = row["targetName"], row["targetName"] != row["sourceName"] {
                linksByName[target, default: []].append(link)
            }
        }

        let decoder = CKRecordDecoder()
        return try rows.compactMap { row in
            guard case .text(let name) = row["_name"] else { return nil }
            let record = R.schema.record(from: row, name: name, zone: zone)
            return try decoder.decode(R.self, from: record, links: linksByName[name] ?? [], depth: 0)
        }
    }

    /// One query that names the table holding a current, undeleted record, given the record's
    /// zone and name once per table. Built once, and its statement is cached like any other.
    private lazy var recordTypeLookup: (sql: String, tables: Int) = {
        let recordTypes = types.keys.filter { $0 != RecordLink.recordType }.sorted()
        let selects = recordTypes.map { recordType in
            let literal = "'" + recordType.replacingOccurrences(of: "'", with: "''") + "'"
            return "SELECT \(literal) AS \"type\" FROM \(database.quoted(recordType)) "
                + "WHERE \(Self.named) AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        }
        return (selects.joined(separator: " UNION ALL ") + " LIMIT 1", recordTypes.count)
    }()

    /// The saved `R` for `key`, with its references holding IDs, or `nil` when it is missing or
    /// deleted.
    private nonisolated static func load<R: Record>(_ type: R.Type, key: RecordKey, in database: Database) throws -> R? {
        guard let row = try currentRow(of: key, in: database), row["_deleted"] != .integer(1) else { return nil }
        let record = R.schema.record(from: row, name: key.name, zone: key.zone)
        // The record's own links, and the links that point at it for its `from:` sides.
        let linkRows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND ("sourceName" = ? OR "targetName" = ?)
            """,
            key.values + [.text(key.name)]
        )
        let links = linkRows.compactMap { row -> CKRecord? in
            guard case .text(let name) = row["_name"] else { return nil }
            return RecordLink.schema.record(from: row, name: name, zone: key.zone)
        }
        return try CKRecordDecoder().decode(R.self, from: record, links: links, depth: 0)
    }

    /// Stops with a message when `R` isn't registered, which is a programmer error.
    private func checkRegistered<R: Record>(_ type: R.Type) {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            preconditionFailure(RecordContextError.unregisteredType(R.recordType).description)
        }
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
