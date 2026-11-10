import Foundation
import SQLite3

/// The container's SQLite connection. Every call runs under one lock, so calls never overlap.
final class Database: @unchecked Sendable {
    /// The columns Records keeps on every record table. Field names can't start with an
    /// underscore, so these never collide with a field.
    static let bookkeeping: [(name: String, definition: String)] = [
        ("_name", "TEXT NOT NULL"),
        ("_isCurrent", "INTEGER NOT NULL"),
        ("_zoneName", "TEXT"),
        ("_zoneOwner", "TEXT"),
        ("_systemFields", "BLOB"),
        ("_createdAt", "REAL"),
        ("_modifiedAt", "REAL"),
        ("_deleted", "INTEGER NOT NULL DEFAULT 0"),
    ]

    /// Holds the sync engine's state for each database scope.
    static let syncStateTable = "_SyncState"

    private let handle: OpaquePointer
    private let lock = NSLock()

    init(_ storage: RecordContainer.Configuration.Storage) throws {
        let path: String
        switch storage {
        case .inMemory:
            path = ":memory:"
        case .file(let url):
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw RecordContainerError.database(error.localizedDescription)
            }
            path = url.path
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            sqlite3_close_v2(handle)
            throw RecordContainerError.database(message)
        }
        self.handle = handle
        if case .file = storage {
            try execute("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    // MARK: - Tables

    /// Creates a table for each schema, or brings an existing one up to date: a new field adds
    /// a column, and a removed field's column is dropped. Also creates the sync state table.
    func createTables(for schemas: [RecordSchema]) throws {
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS \"\(Self.syncStateTable)\" (scope TEXT PRIMARY KEY, state BLOB)")
            for schema in schemas {
                try createTable(for: schema)
            }
        }
    }

    private func createTable(for schema: RecordSchema) throws {
        let table = quoted(schema.recordType)
        let columns = Self.bookkeeping.map { "\(quoted($0.name)) \($0.definition)" }
            + schema.fields.map { quoted($0.key) }
        try execute("CREATE TABLE IF NOT EXISTS \(table) (\(columns.joined(separator: ", ")), PRIMARY KEY (\"_name\", \"_isCurrent\"))")

        let existing = try columnNames(schema.recordType)
        let wanted = Set(schema.fields.map(\.key))
        for field in schema.fields where !existing.contains(field.key) {
            try execute("ALTER TABLE \(table) ADD COLUMN \(quoted(field.key))")
        }
        for column in existing where !column.hasPrefix("_") && !wanted.contains(column) {
            try execute("ALTER TABLE \(table) DROP COLUMN \(quoted(column))")
        }

        // Rows the sync engine has to upload: unsynced edits, new records, and deletes.
        try execute("""
            CREATE INDEX IF NOT EXISTS \(quoted(schema.recordType + "_pending")) ON \(table) ("_name") \
            WHERE "_isCurrent" = 0 OR "_systemFields" IS NULL OR "_deleted" = 1
            """)
        if schema.recordType == RecordLink.recordType {
            // Each side of a relationship finds its links by its own name.
            try execute("CREATE INDEX IF NOT EXISTS \"RecordLink_source\" ON \(table) (\"sourceName\", \"source\")")
            try execute("CREATE INDEX IF NOT EXISTS \"RecordLink_target\" ON \(table) (\"targetName\", \"source\")")
        }
    }

    /// The column names of `table`, in order.
    func columnNames(_ table: String) throws -> [String] {
        try strings("SELECT name FROM pragma_table_info('\(table)')")
    }

    /// The names of the tables in the database, sorted.
    func tableNames() throws -> [String] {
        try strings("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
    }

    /// The names of the indexes on `table`, sorted.
    func indexNames(_ table: String) throws -> [String] {
        try strings("SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = '\(table)' AND sql IS NOT NULL ORDER BY name")
    }

    // MARK: - SQL

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Runs `body` in one transaction, rolled back if it throws.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The first column of each row `sql` returns, as text.
    private func strings(_ sql: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            case SQLITE_DONE:
                return values
            default:
                throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
