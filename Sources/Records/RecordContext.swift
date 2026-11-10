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
/// The app's main actor uses `container.mainContext`. Every write is one transaction, so a
/// record and its links are saved together or not at all.
@MainActor
public final class RecordContext {
    /// Every registered type by record type, shared with the container.
    let types: [CKRecord.RecordType: any Record.Type]
    /// The container's database. The context holds it, not the container, so the container can
    /// keep its main context without the two keeping each other alive.
    let database: Database

    /// The zone new records go to. Set it to switch zones at any time.
    public var zone: Zone = .records

    init(container: RecordContainer) {
        types = container.types
        database = container.database
    }

    /// Saves `record` to the current `zone`, with a link for each reference target and each
    /// `@Asset`. A new record is added. A record already in the zone is replaced by this copy:
    /// it keeps its creation date, and links for targets it no longer has are removed.
    ///
    /// Only `record` itself is saved. Records its references point at are saved by saving them
    /// too.
    public func save<R: Record>(_ record: R) throws {
        try checkRegistered(R.self)
        let row = Row(zone: zone, now: Date())
        let name = record.id.uuidString
        let values = record.columnValues()
        let links = Self.links(for: record).map { ($0.id.uuidString, $0.columnValues()) }
        let database = self.database
        try database.transaction {
            try Self.write(R.schema, name: name, values: values, row: row, in: database)
            for (linkName, linkValues) in links {
                // A one-to-many target moves to its new source, so its link may exist already.
                try Self.write(RecordLink.schema, name: linkName, values: linkValues, row: row, in: database)
            }
            try Self.removeLinks(from: R.recordType, name: name, keeping: links.map(\.0), row: row, in: database)
        }
    }

    // MARK: - Rows

    /// The bookkeeping every row written in one call shares.
    private struct Row: Sendable {
        let zone: Zone
        let now: Date
    }

    /// The bookkeeping columns a write sets. The rest keep their defaults: `_systemFields` is
    /// `NULL` until the first sync, which also marks the row as waiting to upload.
    private nonisolated static let writtenBookkeeping = ["_name", "_isCurrent", "_zoneName", "_zoneOwner", "_createdAt", "_modifiedAt"]

    /// Writes the current row `name` of `schema`'s table in `row.zone`. A row is named by its zone
    /// and name together, as a CloudKit record ID is, so the same name can be in several zones.
    ///
    /// An existing row takes the new fields and modification date, keeps its creation date, and
    /// is no longer deleted. If it has synced and has no base row yet, it is first copied to one,
    /// so the next sync can tell which fields changed since.
    private nonisolated static func write(
        _ schema: RecordSchema, name: String, values: [SQLValue], row: Row, in database: Database
    ) throws {
        let table = database.quoted(schema.recordType)
        try keepBase(of: schema.recordType, name: name, zone: row.zone, in: database)
        let fieldColumns = schema.fields.map { database.quoted($0.key) }
        let columns = Self.writtenBookkeeping.map(database.quoted) + fieldColumns
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updated = ["\"_modifiedAt\""] + fieldColumns
        let sql = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
            + " ON CONFLICT (\"_zoneName\", \"_zoneOwner\", \"_name\", \"_isCurrent\") DO UPDATE SET \"_deleted\" = 0, "
            + updated.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        let seconds = row.now.timeIntervalSince1970
        let bookkeeping: [SQLValue] = [
            .text(name), .integer(1), .text(row.zone.name), .text(row.zone.ownerName), .real(seconds), .real(seconds),
        ]
        try database.run(sql, bookkeeping + values)
    }

    /// Copies the current row `name` to its base row when the current row has synced and no base
    /// row exists. The base row holds the server's last known values until the next upload.
    private nonisolated static func keepBase(
        of recordType: CKRecord.RecordType, name: String, zone: Zone, in database: Database
    ) throws {
        let table = database.quoted(recordType)
        let columns = try database.columnNames(recordType).map(database.quoted)
        let selected = columns.map { $0 == "\"_isCurrent\"" ? "0" : $0 }
        try database.run(
            """
            INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ", "))) \
            SELECT \(selected.joined(separator: ", ")) FROM \(table) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "_name" = ? AND "_isCurrent" = 1 AND "_systemFields" IS NOT NULL
            """,
            [.text(zone.name), .text(zone.ownerName), .text(name)]
        )
    }

    /// Removes the links of `recordType`'s record `name` in `row.zone` other than `kept`. A link
    /// that never synced is deleted. A synced link is marked deleted, keeping a base row, so the
    /// deletion reaches the server.
    private nonisolated static func removeLinks(
        from recordType: CKRecord.RecordType, name: String, keeping kept: [String], row: Row, in database: Database
    ) throws {
        let table = database.quoted(RecordLink.recordType)
        let match = """
            "_zoneName" = ? AND "_zoneOwner" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND "sourceName" = ? AND substr("source", 1, ?) = ?
            """
        let prefix = recordType + "."
        let matchValues: [SQLValue] = [
            .text(row.zone.name), .text(row.zone.ownerName), .text(name), .integer(Int64(prefix.count)), .text(prefix),
        ]
        let links = try database.rows("SELECT \"_name\", \"_systemFields\" FROM \(table) WHERE \(match)", matchValues)
        let zoneValues: [SQLValue] = [.text(row.zone.name), .text(row.zone.ownerName)]
        for link in links {
            guard case .text(let linkName) = link["_name"], !kept.contains(linkName) else { continue }
            let named = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_name\" = ? AND \"_isCurrent\" = 1"
            if link["_systemFields"] == .null {
                try database.run("DELETE FROM \(table) WHERE \(named)", zoneValues + [.text(linkName)])
            } else {
                try keepBase(of: RecordLink.recordType, name: linkName, zone: row.zone, in: database)
                try database.run(
                    "UPDATE \(table) SET \"_deleted\" = 1, \"_modifiedAt\" = ? WHERE \(named)",
                    [.real(row.now.timeIntervalSince1970)] + zoneValues + [.text(linkName)]
                )
            }
        }
    }

    // MARK: - Links

    /// A link for each target of each reference that writes links, in order, and one for each
    /// `@Asset` that holds data.
    nonisolated static func links<R: Record>(for record: R) -> [RecordLink] {
        let references = record.referenceStates.flatMap { reference -> [RecordLink] in
            // A sorted reference is ordered by its records' fields, so its links carry no keys.
            let orders: [String?] = reference.isToMany && !reference.isSorted
                ? OrderKey.assign(reference.ids.map { _ in nil })
                : reference.ids.map { _ in nil }
            return zip(reference.ids, orders).map { id, order in
                RecordLink(reference: reference, sourceType: R.recordType, sourceID: record.id, target: ReferenceTarget(id: id, order: order))
            }
        }
        let assets = record.assetStates.compactMap { asset in
            asset.id.map { RecordLink(asset: asset, assetID: $0, sourceType: R.recordType, sourceID: record.id) }
        }
        return references + assets
    }

    // MARK: - Types

    private func checkRegistered<R: Record>(_ type: R.Type) throws {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            throw RecordContextError.unregisteredType(R.recordType)
        }
    }
}
