import Foundation
import SQLite3

/// Reads the app's database file directly and read-only, to show what Records keeps to itself:
/// how many rows wait to upload and how many the server has confirmed. Records needs no
/// test-only API for this.
enum Inspector {
    /// One table's rows.
    struct Table: Identifiable {
        let id: String
        /// Records that exist now.
        let records: Int
        /// Records waiting to upload: new, edited or deleted since the server last confirmed them.
        let pending: Int
        /// Records the server has confirmed at least once.
        let synced: Int
    }

    static var databaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Records/default.records", directoryHint: .notDirectory)
    }

    static var assetsURL: URL {
        URL.applicationSupportDirectory.appending(path: "Records/Assets", directoryHint: .isDirectory)
    }

    /// Every record table, links included, or none when the file can't be read.
    static func tables() -> [Table] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        let names = column(handle, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix("sqlite_") }
        return names.map { name in
            let table = "\"\(name)\""
            return Table(
                id: name,
                records: count(handle, "SELECT COUNT(*) FROM \(table) WHERE \"_isCurrent\" = 1 AND \"_deleted\" = 0"),
                pending: count(handle, """
                    SELECT COUNT(DISTINCT "_name") FROM \(table) \
                    WHERE "_isCurrent" = 0 OR "_systemFields" IS NULL OR "_deleted" = 1
                    """),
                synced: count(handle, "SELECT COUNT(*) FROM \(table) WHERE \"_isCurrent\" = 1 AND \"_systemFields\" IS NOT NULL")
            )
        }
    }

    /// The scopes the sync state table holds: `private` once the sync engine has saved its
    /// state, and `schema` once the types have been recorded.
    static func syncState() -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        return column(handle, "SELECT scope FROM \"_SyncState\" ORDER BY scope")
    }

    /// The asset files on disk and their total size.
    static func assetFiles() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (files.count, bytes)
    }

    private static func column(_ handle: OpaquePointer, _ sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private static func count(_ handle: OpaquePointer, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }
}
