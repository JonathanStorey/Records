import CloudKit
import Foundation

/// Why a `RecordContext` couldn't read or write a record.
public enum RecordContextError: Error, Equatable, CustomStringConvertible {
    /// The record's type isn't registered with the container.
    case unregisteredType(String)
    /// A record with this ID already exists.
    case duplicateID(UUID)

    public var description: String {
        switch self {
        case .unregisteredType(let type):
            "'\(type)' isn't registered with this container. Pass it, or a type that refers to it, to RecordContainer(for:)."
        case .duplicateID(let id):
            "A record with the ID \(id) already exists."
        }
    }
}

/// Reads and writes records in a container's database.
///
/// The app's main actor uses `container.mainContext`. Every write is one transaction, so a
/// record and its links are saved together or not at all.
@MainActor
public final class RecordContext {
    /// The container whose database this context reads and writes.
    public let container: RecordContainer

    /// The zone new records go to. Set it to switch zones at any time.
    public var zone: Zone = .records

    init(container: RecordContainer) {
        self.container = container
    }

    /// Saves a new record to the current `zone`, with a link for each reference target and each
    /// `@Asset`.
    ///
    /// Only `record` itself is saved. Records its references point at are saved by inserting
    /// them too. Throws `RecordContextError.duplicateID` when a record with the same ID exists.
    public func insert<R: Record>(_ record: R) throws {
        try checkRegistered(R.self)
        let row = Row(zone: zone, now: Date())
        let values = record.columnValues()
        let links = Self.links(for: record).map { ($0.id, $0.columnValues()) }
        let database = container.database
        do {
            try database.transaction {
                try Self.write(R.schema, name: record.id.uuidString, values: values, row: row, replacing: false, in: database)
                for (id, linkValues) in links {
                    // A one-to-many target moves to its new source, so its link may exist already.
                    try Self.write(RecordLink.schema, name: id.uuidString, values: linkValues, row: row, replacing: true, in: database)
                }
            }
        } catch is Database.ConstraintViolation {
            throw RecordContextError.duplicateID(record.id)
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

    /// Writes the current row `name` of `schema`'s table. With `replacing`, an existing row
    /// takes the new fields, zone, and modification date, and keeps the rest.
    private nonisolated static func write(
        _ schema: RecordSchema, name: String, values: [SQLValue], row: Row, replacing: Bool, in database: Database
    ) throws {
        let fieldColumns = schema.fields.map { database.quoted($0.key) }
        let columns = Self.writtenBookkeeping.map(database.quoted) + fieldColumns
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        var sql = "INSERT INTO \(database.quoted(schema.recordType)) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        if replacing {
            let updated = ["\"_zoneName\"", "\"_zoneOwner\"", "\"_modifiedAt\""] + fieldColumns
            sql += " ON CONFLICT (\"_name\", \"_isCurrent\") DO UPDATE SET "
                + updated.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
        }
        let seconds = row.now.timeIntervalSince1970
        let bookkeeping: [SQLValue] = [
            .text(name), .integer(1), .text(row.zone.name), .text(row.zone.ownerName), .real(seconds), .real(seconds),
        ]
        try database.run(sql, bookkeeping + values)
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
        guard let registered = container.types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            throw RecordContextError.unregisteredType(R.recordType)
        }
    }
}
