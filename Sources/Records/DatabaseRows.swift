import CloudKit
import Foundation

/// Reading and writing record and link rows. Every record table has the columns in
/// `bookkeeping` plus one per field. A record has a current row, and a base row while a synced
/// record has edits that haven't uploaded.
extension Database {
    /// Matches one record's rows by zone and name.
    static let named = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_name\" = ?"

    /// The condition for current, undeleted rows in `zone` that meet `filter`, and its values.
    static func matching(zone: Zone, filter: SQLFilter?) -> (sql: String, values: [SQLValue]) {
        let current = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        let zoneValues: [SQLValue] = [.text(zone.name), .text(zone.ownerName)]
        return (current + (filter.map { " AND \($0.sql)" } ?? ""), zoneValues + (filter?.values ?? []))
    }

    /// Every saved, undeleted `R` in `zone` that meets `filter`, in the order and range of `page`
    /// when given, with references holding IDs. One query reads the rows and one reads every
    /// link they own or are the target of.
    func loadAll<R: Record>(
        _ type: R.Type, zone: Zone, filter: SQLFilter?, page: SQLPage?
    ) throws -> [R] {
        let table = quoted(R.recordType)
        var (matching, matchingValues) = Self.matching(zone: zone, filter: filter)
        if let page {
            matching += " ORDER BY \(page.orderBy) LIMIT ? OFFSET ?"
            matchingValues += [.integer(Int64(page.limit ?? -1)), .integer(Int64(page.offset))]
        }
        let rows = try self.rows("SELECT * FROM \(table) WHERE \(matching)", matchingValues)
        guard !rows.isEmpty else { return [] }

        let (current, zoneValues) = Self.matching(zone: zone, filter: nil)
        let names = "SELECT \"_name\" FROM \(table) WHERE \(matching)"
        let linkRows = try self.rows(
            """
            SELECT * FROM \(quoted(RecordLink.recordType)) WHERE \(current) \
            AND ("sourceName" IN (\(names)) OR "targetName" IN (\(names)))
            """,
            zoneValues + matchingValues + matchingValues
        )
        var graph = RecordGraph()
        for row in linkRows {
            guard case .text(let name) = row["_name"] else { continue }
            graph.addLink(row, name: name)
        }
        return try rows.map { row in
            var record = try R(from: RecordRow(row))
            try graph.load(&record, depth: 0)
            return record
        }
    }

    /// The saved `R` for `key`, with its references holding IDs, or `nil` when it is missing or
    /// deleted.
    func load<R: Record>(_ type: R.Type, key: RecordKey) throws -> R? {
        guard let row = try currentRow(of: key), row["_deleted"] != .integer(1) else { return nil }
        var record = try R(from: RecordRow(row))
        var graph = RecordGraph()
        for (name, row) in try savedLinks(touching: key) {
            graph.addLink(row, name: name)
        }
        try graph.load(&record, depth: 0)
        return record
    }

    /// The record's own saved links, and the saved links that point at it for its `from:` sides,
    /// by link name.
    func savedLinks(touching key: RecordKey) throws -> [String: [String: SQLValue]] {
        let rows = try self.rows(
            """
            SELECT * FROM \(quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND ("sourceName" = ? OR "targetName" = ?)
            """,
            key.values + [.text(key.name)]
        )
        return Dictionary(
            rows.compactMap { row in
                guard case .text(let name) = row["_name"] else { return nil }
                return (name, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Whether a current link from `source` points at `targetName`.
    func isLinked(source: String, targetName: String, zone: Zone) throws -> Bool {
        try !self.rows(
            """
            SELECT 1 FROM \(quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "source" = ? AND "targetName" = ? \
            AND "_isCurrent" = 1 AND "_deleted" = 0 LIMIT 1
            """,
            [.text(zone.name), .text(zone.ownerName), .text(source), .text(targetName)]
        ).isEmpty
    }

    /// Writes one edit: the record's row and its links. With a base, only the fields and links
    /// the edit changed from it are written, so the saved record keeps anything changed
    /// elsewhere since that the edit didn't touch.
    func write(_ change: RecordDifference, now: Double) throws {
        let key = change.key
        let savedLinks = try currentLinks(of: key)
        guard !change.isDelete else {
            try remove(key, now: now)
            try writeLinks([], of: key, saved: savedLinks, removing: nil, now: now)
            return
        }
        // A record removed or deleted since it was edited comes back whole.
        let savedRow = try currentRow(of: key)
        let hasOriginal = savedRow != nil && savedRow?["_deleted"] != .integer(1) && change.base != nil
        let edited = hasOriginal ? change.originalValues.map { original in change.values.filter { original[$0.key] != $0.value } } : nil
        try writeRecord(change.schema, key: key, values: change.values, edited: edited, now: now)

        let orders = RecordContext.orders(of: savedLinks)
        let links = change.links(orders)
        guard hasOriginal, let originalLinks = change.originalLinks(orders) else {
            try writeLinks(links, of: key, saved: savedLinks, removing: nil, now: now)
            return
        }
        let original = Dictionary(originalLinks, uniquingKeysWith: { first, _ in first })
        let kept = Set(links.map(\.0))
        try writeLinks(
            links.filter { !RecordContext.matches(original[$0.0], $0.1) }, of: key, saved: savedLinks,
            removing: Set(original.keys.filter { !kept.contains($0) }), now: now
        )
    }

    /// Writes an edited record. A new one is inserted with every field. An existing one has the
    /// fields that differ updated, and a deleted one comes back with every field. Before a synced
    /// row first changes, it is copied to its base row, and once it matches its base again the
    /// base is dropped.
    func writeRecord(
        _ schema: RecordSchema, key: RecordKey, values: [String: SQLValue], edited: [String: SQLValue]?,
        now: Double
    ) throws {
        guard let saved = try currentRow(of: key) else {
            try insertRow(schema.recordType, key: key, fields: values, now: now)
            return
        }
        // A deleted row comes back whole. Otherwise only the edited fields count, or every field
        // when there is no original to compare with.
        let candidates = saved["_deleted"] == .integer(1) ? values : (edited ?? values)
        let fields = saved["_deleted"] == .integer(1) ? values : candidates.filter { saved[$0.key] != $0.value }
        guard !fields.isEmpty else { return }
        try keepBase(of: key)
        try updateRow(key, fields: fields, now: now)
        try dropBaseIfUnchanged(key, schema: schema)
    }

    /// Writes `links` where they differ from the saved ones. Removes the saved links named in
    /// `removing`, or, when it is `nil`, every saved link not in `links`.
    func writeLinks(
        _ links: [(String, [String: SQLValue])], of key: RecordKey, saved: [String: [String: SQLValue]],
        removing: Set<String>?, now: Double
    ) throws {
        for (name, values) in links where !RecordContext.matches(saved[name], values) {
            let linkKey = RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone)
            if try currentRow(of: linkKey) == nil {
                try insertRow(RecordLink.recordType, key: linkKey, fields: values, now: now)
            } else {
                // A one-to-many target moves to its new source, so its link may belong to another record.
                try keepBase(of: linkKey)
                try updateRow(linkKey, fields: values, now: now)
                try dropBaseIfUnchanged(linkKey, schema: RecordLink.schema)
            }
        }
        let kept = Set(links.map(\.0))
        for name in saved.keys where removing?.contains(name) ?? !kept.contains(name) {
            try remove(RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone), now: now)
        }
    }

    /// Removes the current row of `key`. A row that never synced is deleted with any base row.
    /// A synced row is marked deleted, so the deletion reaches the server.
    func remove(_ key: RecordKey, now: Double) throws {
        guard let row = try currentRow(of: key) else { return }
        let table = quoted(key.recordType)
        if row["_systemFields"] == .null {
            try run("DELETE FROM \(table) WHERE \(Self.named)", key.values)
        } else {
            try run(
                "UPDATE \(table) SET \"_deleted\" = 1, \"_modifiedAt\" = ? WHERE \(Self.named) AND \"_isCurrent\" = 1",
                [.real(now)] + key.values
            )
        }
    }

    func insertRow(
        _ recordType: CKRecord.RecordType, key: RecordKey, fields: [String: SQLValue], now: Double
    ) throws {
        let names = Array(fields.keys)
        let columns = ["_name", "_isCurrent", "_zoneName", "_zoneOwner", "_createdAt", "_modifiedAt"] + names
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try run(
            "INSERT INTO \(quoted(recordType)) (\(columns.map(quoted).joined(separator: ", "))) VALUES (\(placeholders))",
            [.text(key.name), .integer(1), .text(key.zone.name), .text(key.zone.ownerName), .real(now), .real(now)]
                + names.map { fields[$0]! }
        )
    }

    func updateRow(_ key: RecordKey, fields: [String: SQLValue], now: Double) throws {
        let names = Array(fields.keys)
        let assignments = ["\"_deleted\" = 0", "\"_modifiedAt\" = ?"] + names.map { "\(quoted($0)) = ?" }
        try run(
            "UPDATE \(quoted(key.recordType)) SET \(assignments.joined(separator: ", ")) WHERE \(Self.named) AND \"_isCurrent\" = 1",
            [.real(now)] + names.map { fields[$0]! } + key.values
        )
    }

    /// Copies the current row of `key` to its base row when the current row has synced and no
    /// base row exists. The base row holds the server's last known values until the next upload.
    func keepBase(of key: RecordKey) throws {
        let table = quoted(key.recordType)
        let columns = try columnNames(key.recordType).map(quoted)
        let selected = columns.map { $0 == "\"_isCurrent\"" ? "0" : $0 }
        try run(
            """
            INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ", "))) \
            SELECT \(selected.joined(separator: ", ")) FROM \(table) \
            WHERE \(Self.named) AND "_isCurrent" = 1 AND "_systemFields" IS NOT NULL
            """,
            key.values
        )
    }

    /// Drops the base row of `key` when the current row's fields match it again, so an edit that
    /// is undone leaves the record with nothing to upload.
    func dropBaseIfUnchanged(_ key: RecordKey, schema: RecordSchema) throws {
        let rows = try self.rows("SELECT * FROM \(quoted(key.recordType)) WHERE \(Self.named)", key.values)
        guard let current = rows.first(where: { $0["_isCurrent"] == .integer(1) }),
              let base = rows.first(where: { $0["_isCurrent"] == .integer(0) }),
              current["_deleted"] == .integer(0),
              schema.fields.allSatisfy({ current[$0.key] == base[$0.key] })
        else { return }
        try run(
            "DELETE FROM \(quoted(key.recordType)) WHERE \(Self.named) AND \"_isCurrent\" = 0", key.values
        )
    }

    /// The current row of `key`, or `nil` when there is none.
    func currentRow(of key: RecordKey) throws -> [String: SQLValue]? {
        try self.rows(
            "SELECT * FROM \(quoted(key.recordType)) WHERE \(Self.named) AND \"_isCurrent\" = 1", key.values
        ).first
    }

    /// The current, undeleted links `key`'s record owns, by link name.
    func currentLinks(of key: RecordKey) throws -> [String: [String: SQLValue]] {
        let prefix = key.recordType + "."
        let rows = try self.rows(
            """
            SELECT * FROM \(quoted(RecordLink.recordType)) \
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
}
