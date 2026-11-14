import CloudKit
import Foundation
import os

/// Where sync reports what it skipped and why: Xcode's console and the Console app.
let syncLog = Logger(subsystem: "Records", category: "Sync")

/// How sync writes the server's changes into the rows, and builds what it uploads.
///
/// Each record has up to three copies. Base is the server's copy the local edits started from:
/// the base row (`_isCurrent = 0`), or the current row when there is no base row. Ours is the
/// current row. Theirs is a `CKRecord` from the server. An `@Asset` is a `RecordLink`, so its
/// three copies are its link's, and each copy's `assetID` names its own file.
///
/// The functions take plain values and never touch a context. The caller wraps each batch in one
/// transaction and rebases the contexts after it.
extension Database {
    // MARK: - Merge

    /// The fields of a record both sides changed since `base`, merged.
    ///
    /// A field ours didn't change takes theirs. A field theirs didn't change keeps ours. A field
    /// both changed to different values takes the field's strategy, which is ours until
    /// `@Merged` exists. With no base, every field that differs counts as changed on both sides.
    ///
    /// A `RecordLink` merges as one value, so an asset's ID never travels without its file and a
    /// link never points at one side's target from the other side's source.
    static func merged(
        base: [String: SQLValue]?, ours: [String: SQLValue], theirs: [String: SQLValue], schema: RecordSchema
    ) -> [String: SQLValue] {
        func unchanged(_ field: FieldSchema) -> Bool {
            guard let base else { return false }
            return (ours[field.key] ?? .null) == (base[field.key] ?? .null)
        }
        if schema.recordType == RecordLink.recordType {
            let winner = schema.fields.allSatisfy(unchanged) ? theirs : ours
            return Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.key, winner[$0.key] ?? .null) })
        }
        return Dictionary(uniqueKeysWithValues: schema.fields.map { field in
            (field.key, (unchanged(field) ? theirs[field.key] : ours[field.key]) ?? .null)
        })
    }

    // MARK: - Receiving

    /// Writes `record`, fetched from the server, into its rows.
    ///
    /// | Local state | Result |
    /// | --- | --- |
    /// | No row | Theirs is inserted as a synced row. |
    /// | Synced | Theirs replaces the row. |
    /// | Edited | The fields merge. Theirs becomes the base, and the record stays pending when the result differs from it. |
    /// | New, with the same ID | The fields merge with no base, so ours wins every field that differs. |
    /// | Deleted | Their edit wins, and the record returns with their values. The server copy our deletion was made against, fetched again, changes nothing. |
    ///
    /// Applying the same server copy twice changes nothing, so a repeated fetch is harmless.
    ///
    /// An asset's file is copied from CloudKit's temporary file into `assets` first, because
    /// CloudKit may delete its file once the event is handled. A file already there is kept.
    func apply(_ record: CKRecord, schema: RecordSchema, assets: URL) throws {
        let theirs = try schema.values(of: record)
        try copyAsset(of: record, into: assets)
        let key = Self.key(of: record.recordID, recordType: record.recordType)
        let server = ServerCopy(record)
        let rows = try self.rows(of: key)
        guard let ours = rows.current else {
            return try writeRow(key, isCurrent: true, fields: theirs, schema: schema, server: server, existing: nil)
        }
        if ours["_deleted"] == .integer(1) {
            // Our deletion stands against the server copy it deleted. Only a newer edit wins.
            let deleted = RecordRow(rows.base ?? ours).serverRecord(recordType: key.recordType, name: key.name, zone: key.zone)
            if let tag = record.recordChangeTag, tag == deleted?.recordChangeTag { return }
        }
        if ours["_deleted"] == .integer(1) || (rows.base == nil && ours["_systemFields"] != .null) {
            try deleteBase(of: key)
            return try writeRow(key, isCurrent: true, fields: theirs, schema: schema, server: server, existing: ours)
        }
        let merged = Self.merged(base: rows.base, ours: ours, theirs: theirs, schema: schema)
        try writeRow(key, isCurrent: false, fields: theirs, schema: schema, server: server, existing: rows.base ?? ours)
        try writeRow(key, isCurrent: true, fields: merged, schema: schema, server: server, existing: ours, keepsLocalDates: true)
        try dropBaseIfUnchanged(key, schema: schema)
    }

    /// Applies the server's deletion of the record with `recordID`.
    ///
    /// | Local state | Result |
    /// | --- | --- |
    /// | Synced | The rows are removed. |
    /// | Edited | The edit wins. The server copy is forgotten, so the record uploads as new. |
    /// | New, with the same ID | Nothing. It still uploads as new. |
    /// | Deleted | The rows are removed. Both sides agree. |
    /// | No row | Nothing. |
    ///
    /// No cascade runs. The device that deleted the record deleted what it owned, and those
    /// deletions arrive as their own changes.
    func applyDeletion(of recordID: CKRecord.ID, recordType: CKRecord.RecordType) throws {
        let key = Self.key(of: recordID, recordType: recordType)
        let rows = try self.rows(of: key)
        guard let ours = rows.current else { return }
        if ours["_deleted"] == .integer(1) || (rows.base == nil && ours["_systemFields"] != .null) {
            try removeRows(of: key)
        } else if rows.base != nil {
            try forgetServerCopy(of: key)
        }
    }

    // MARK: - Sending

    /// The record to upload for the record with `recordID`, or `nil` when it no longer needs to
    /// be saved: its row is gone, synced, or deleted, which uploads as a deletion instead.
    ///
    /// A row that has synced starts from the server's last copy, so the upload carries its change
    /// tag. Every field is set from the current row, so fields a newer version of the app added
    /// are never touched. An asset's link carries the asset's file, and a link whose file is
    /// missing returns `nil`, because sending it without the file would erase the asset on every
    /// device.
    func recordToSend(for recordID: CKRecord.ID, schema: RecordSchema, assets: URL) throws -> CKRecord? {
        let key = Self.key(of: recordID, recordType: schema.recordType)
        let rows = try self.rows(of: key)
        guard let ours = rows.current, ours["_deleted"] != .integer(1),
              rows.base != nil || ours["_systemFields"] == .null
        else { return nil }
        let zone = key.zone
        let server = RecordRow(ours).serverRecord(recordType: key.recordType, name: key.name, zone: zone)
        let record = schema.record(from: ours, name: key.name, zone: zone, onto: server)
        if schema.recordType == RecordLink.recordType, case .text(let assetID) = ours["assetID"] {
            let file = assets.appending(path: "\(assetID).asset", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: file.path) else {
                syncLog.error("Skipped link \(key.name, privacy: .public): its asset file \(assetID, privacy: .public) is missing")
                return nil
            }
            record[RecordLink.assetKey] = CKAsset(fileURL: file)
        }
        return record
    }

    /// Records that the server saved `record`, which this device uploaded.
    ///
    /// | Report | The current row equals what was sent | The current row changed during the upload |
    /// | --- | --- | --- |
    /// | Saved | The server copy and dates are stored and the base row is dropped. The record is synced. | The server copy is stored on both rows, and the base row takes the saved values. The record stays pending. |
    ///
    /// A record deleted during the upload keeps its deletion pending. A record that never synced
    /// and was deleted during the upload has no row left, so a deleted row is written for it,
    /// and the deletion reaches the server too.
    func acknowledge(saved record: CKRecord, schema: RecordSchema) throws {
        let sent = try schema.values(of: record)
        let key = Self.key(of: record.recordID, recordType: record.recordType)
        let server = ServerCopy(record)
        let rows = try self.rows(of: key)
        guard let ours = rows.current else {
            try writeRow(key, isCurrent: true, fields: sent, schema: schema, server: server, existing: nil)
            try run("UPDATE \(quoted(key.recordType)) SET \"_deleted\" = 1 WHERE \(Self.named)", key.values)
            return
        }
        let isDeleted = ours["_deleted"] == .integer(1)
        if !isDeleted, schema.fields.allSatisfy({ (ours[$0.key] ?? .null) == sent[$0.key] }) {
            try deleteBase(of: key)
            try writeRow(key, isCurrent: true, fields: sent, schema: schema, server: server, existing: ours)
        } else {
            try writeRow(key, isCurrent: false, fields: sent, schema: schema, server: server, existing: rows.base ?? ours)
            try run("UPDATE \(quoted(key.recordType)) SET \"_systemFields\" = ? WHERE \(Self.named)", [server.systemFields] + key.values)
            try dropBaseIfUnchanged(key, schema: schema)
        }
    }

    /// Records that the server deleted the record with `recordID`, which this device uploaded.
    ///
    /// | Report | The row is still deleted | The record was saved again during the upload |
    /// | --- | --- | --- |
    /// | Deleted | Both rows are removed. | The server copy is forgotten, so the record uploads as new. |
    func acknowledge(deleted recordID: CKRecord.ID, recordType: CKRecord.RecordType) throws {
        let key = Self.key(of: recordID, recordType: recordType)
        guard let ours = try currentRow(of: key) else { return }
        if ours["_deleted"] == .integer(1) {
            try removeRows(of: key)
        } else {
            try forgetServerCopy(of: key)
        }
    }

    /// Handles a failed upload of the record with `recordID`, and returns whether it must be
    /// handed to the engine again.
    ///
    /// | Error | Action |
    /// | --- | --- |
    /// | `serverRecordChanged` | The error's server record merges in as theirs, as a fetch would. Sent again while still pending. |
    /// | `zoneNotFound`, `unknownItem` | The server copy is forgotten, so the record uploads as new. A deletion the server can't find is done, so its rows are removed. |
    /// | `batchRequestFailed` | Sent again while still pending. Another record in its batch failed. |
    /// | Network, throttling, busy zone, not signed in, cancelled, `quotaExceeded` | Nothing. The engine retries, or the next save tries again. |
    /// | Anything else | Logged. Never sent again in a loop. |
    func resolve(
        _ error: CKError, for recordID: CKRecord.ID, schema: RecordSchema, assets: URL
    ) throws -> Bool {
        let key = Self.key(of: recordID, recordType: schema.recordType)
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else { return false }
            try apply(server, schema: schema, assets: assets)
            return try isPending(key)
        case .zoneNotFound, .unknownItem:
            guard let ours = try currentRow(of: key) else { return false }
            if ours["_deleted"] == .integer(1) {
                try removeRows(of: key)
                return false
            }
            try forgetServerCopy(of: key)
            return true
        case .batchRequestFailed:
            return try isPending(key)
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .quotaExceeded:
            return false
        default:
            syncLog.error("Upload of \(key.recordType, privacy: .public) \(key.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether the record at `key` has work to upload, as the pending index counts it.
    func isPending(_ key: RecordKey) throws -> Bool {
        try !self.rows(
            """
            SELECT 1 FROM \(quoted(key.recordType)) WHERE \(Self.named) \
            AND ("_isCurrent" = 0 OR "_systemFields" IS NULL OR "_deleted" = 1)
            """,
            key.values
        ).isEmpty
    }

    /// Every record with work to upload, and whether that work is its deletion. The condition
    /// is the pending index's own, so SQLite reads only the index's rows, never the whole table.
    func pendingChanges() throws -> [(key: RecordKey, isDelete: Bool)] {
        var changes: [RecordKey: Bool] = [:]
        for recordType in try recordTables() {
            let rows = try self.rows(
                """
                SELECT "_name", "_zoneName", "_zoneOwner", "_isCurrent", "_deleted" FROM \(quoted(recordType)) \
                WHERE "_isCurrent" = 0 OR "_systemFields" IS NULL OR "_deleted" = 1
                """
            )
            // A record with a base row appears twice. Its current row says whether it is deleted.
            for row in rows {
                guard case .text(let name) = row["_name"], case .text(let zoneName) = row["_zoneName"],
                      case .text(let owner) = row["_zoneOwner"], Zone.isAllowed(zoneName)
                else { continue }
                let key = RecordKey(recordType: recordType, name: name, zone: Zone(zoneName, ownerName: owner))
                let isDelete = row["_isCurrent"] == .integer(1) && row["_deleted"] == .integer(1)
                changes[key] = (changes[key] ?? false) || isDelete
            }
        }
        return changes.map { (key: $0.key, isDelete: $0.value) }
    }

    /// The record type whose table holds `recordID`'s rows, or `nil` when none does. The engine
    /// names records by ID alone, and every record's name is a UUID, so at most one table does.
    func recordType(of recordID: CKRecord.ID) throws -> CKRecord.RecordType? {
        let values = Self.key(of: recordID, recordType: "").values
        for table in try recordTables() {
            if try !rows("SELECT 1 FROM \(quoted(table)) WHERE \(Self.named) LIMIT 1", values).isEmpty {
                return table
            }
        }
        return nil
    }

    // MARK: - Sync state

    /// The value saved under `key` in the sync state table, or `nil`.
    func syncState(_ key: String) throws -> SQLValue? {
        try rows("SELECT \"state\" FROM \(quoted(Self.syncStateTable)) WHERE \"scope\" = ?", [.text(key)]).first?["state"]
    }

    /// Saves `value` under `key`, or removes `key` when `value` is `nil`.
    func setSyncState(_ value: SQLValue?, for key: String) throws {
        let table = quoted(Self.syncStateTable)
        if let value {
            try run("INSERT OR REPLACE INTO \(table) (\"scope\", \"state\") VALUES (?, ?)", [.text(key), value])
        } else {
            try run("DELETE FROM \(table) WHERE \"scope\" = ?", [.text(key)])
        }
    }

    // MARK: - Zones and accounts

    /// Removes every row in `zone`, after the zone was deleted or purged.
    func removeRecords(in zone: Zone) throws {
        for table in try recordTables() {
            try run("DELETE FROM \(quoted(table)) WHERE \"_zoneName\" = ? AND \"_zoneOwner\" = ?", [.text(zone.name), .text(zone.ownerName)])
        }
    }

    /// Forgets the server copy of every record in `zone`, after the user reset their encrypted
    /// data, so every record uploads again as new. Deletions waiting to upload are dropped, since
    /// the server no longer has those records.
    func clearSystemFields(in zone: Zone) throws {
        let values: [SQLValue] = [.text(zone.name), .text(zone.ownerName)]
        let inZone = "\"_zoneName\" = ? AND \"_zoneOwner\" = ?"
        for table in try recordTables().map(quoted) {
            try run("DELETE FROM \(table) WHERE \(inZone) AND (\"_isCurrent\" = 0 OR \"_deleted\" = 1)", values)
            try run("UPDATE \(table) SET \"_systemFields\" = NULL WHERE \(inZone)", values)
        }
    }

    /// Removes every record, after the user signed out or switched accounts, so one person's
    /// records never upload into the next account.
    func removeAllRecords() throws {
        for table in try recordTables() {
            try run("DELETE FROM \(quoted(table))", [])
        }
    }

    // MARK: - Asset files

    /// Deletes each `.asset` file in `folder` that no link row names, current or base.
    ///
    /// Only the container calls it, when it opens and before any context exists. Setting an
    /// `@Asset` writes its file before `save()`, so during a session an unsaved edit's file is
    /// named by no row, and removing it would lose the user's new data.
    func removeUnusedAssetFiles(in folder: URL) throws {
        let named = Set(try rows("SELECT \"assetID\" FROM \(quoted(RecordLink.recordType)) WHERE \"assetID\" IS NOT NULL").compactMap { row -> String? in
            if case .text(let id) = row["assetID"] { id } else { nil }
        })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "asset" && !named.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Rows

    /// What the server says about a record: its system fields, archived, and its dates.
    private struct ServerCopy {
        let systemFields: SQLValue
        let createdAt: Date?
        let modifiedAt: Date?

        init(_ record: CKRecord) {
            systemFields = RecordRow.systemFields(of: record)
            createdAt = record.creationDate
            modifiedAt = record.modificationDate
        }
    }

    static func key(of recordID: CKRecord.ID, recordType: CKRecord.RecordType) -> RecordKey {
        RecordKey(recordType: recordType, name: recordID.recordName, zone: Zone(recordID.zoneID))
    }

    /// The current and base rows of `key`.
    private func rows(of key: RecordKey) throws -> (current: [String: SQLValue]?, base: [String: SQLValue]?) {
        let rows = try self.rows("SELECT * FROM \(quoted(key.recordType)) WHERE \(Self.named)", key.values)
        return (rows.first { $0["_isCurrent"] == .integer(1) }, rows.first { $0["_isCurrent"] == .integer(0) })
    }

    /// Writes one row of `key` whole, with `fields` and the server's copy, replacing any row
    /// there. A date the server didn't give keeps `existing`'s. With `keepsLocalDates`, the
    /// modified date stays `existing`'s, because the row holds local edits.
    private func writeRow(
        _ key: RecordKey, isCurrent: Bool, fields: [String: SQLValue], schema: RecordSchema,
        server: ServerCopy, existing: [String: SQLValue]?, keepsLocalDates: Bool = false
    ) throws {
        func date(_ server: Date?, _ column: String) -> SQLValue {
            server.map { .real($0.timeIntervalSinceReferenceDate) } ?? existing?[column] ?? .null
        }
        let modified = keepsLocalDates ? existing?["_modifiedAt"] ?? .null : date(server.modifiedAt, "_modifiedAt")
        let names = schema.fields.map(\.key)
        let columns = ["_name", "_isCurrent", "_zoneName", "_zoneOwner", "_systemFields", "_createdAt", "_modifiedAt", "_deleted"] + names
        let values: [SQLValue] = [
            .text(key.name), .integer(isCurrent ? 1 : 0), .text(key.zone.name), .text(key.zone.ownerName),
            server.systemFields, date(server.createdAt, "_createdAt"), modified, .integer(0),
        ] + names.map { fields[$0] ?? .null }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try run(
            "INSERT OR REPLACE INTO \(quoted(key.recordType)) (\(columns.map(quoted).joined(separator: ", "))) VALUES (\(placeholders))",
            values
        )
    }

    /// Forgets the server's copy of `key`, so the record uploads as new.
    private func forgetServerCopy(of key: RecordKey) throws {
        try deleteBase(of: key)
        try run("UPDATE \(quoted(key.recordType)) SET \"_systemFields\" = NULL WHERE \(Self.named)", key.values)
    }

    private func deleteBase(of key: RecordKey) throws {
        try run("DELETE FROM \(quoted(key.recordType)) WHERE \(Self.named) AND \"_isCurrent\" = 0", key.values)
    }

    private func removeRows(of key: RecordKey) throws {
        try run("DELETE FROM \(quoted(key.recordType)) WHERE \(Self.named)", key.values)
    }

    /// Every table that holds records, links included.
    private func recordTables() throws -> [String] {
        try tableNames().filter { !$0.hasPrefix("_") && !$0.hasPrefix("sqlite_") }
    }

    /// Copies a fetched asset link's file into `folder` as `<assetID>.asset`, unless it is there.
    /// Sync calls it before the batch's transaction, so file copies never hold the database
    /// lock, and `apply` calls it again, which finds the file there.
    func copyAsset(of record: CKRecord, into folder: URL) throws {
        guard record.recordType == RecordLink.recordType, let assetID = record["assetID"] as? String,
              let file = (record[RecordLink.assetKey] as? CKAsset)?.fileURL
        else { return }
        let destination = folder.appending(path: "\(assetID).asset", directoryHint: .notDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: destination)
    }
}
