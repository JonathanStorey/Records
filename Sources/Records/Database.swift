import Foundation
import SQLite3

/// The container's SQLite connection. Every call runs under one lock, and a transaction holds
/// it throughout, so calls never overlap or land inside another caller's transaction.
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
    private let lock = NSRecursiveLock()
    /// Prepared statements by their SQL, reused for every call.
    private var statements: [String: OpaquePointer] = [:]

    /// A write that broke a uniqueness rule, such as a record name already in use.
    struct ConstraintViolation: Error {}

    /// Opens the database file at `url`, creating it and its folder if needed, or a database in
    /// memory when `url` is `nil`.
    init(url: URL?) throws {
        var path = ":memory:"
        if let url {
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
        if url != nil {
            try execute("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
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

    /// Runs `body` in one transaction, rolled back if it throws. Holds the lock throughout, so
    /// no other call runs in between.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs one statement with `values` bound to its `?` parameters, in order. Throws
    /// `ConstraintViolation` when it breaks a uniqueness rule.
    func run(_ sql: String, _ values: [SQLValue]) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            if result & 0xFF == SQLITE_CONSTRAINT { throw ConstraintViolation() }
            throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Every row `sql` returns with `values` bound, each as its columns by name.
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        try bind(values, to: statement)
        var rows: [[String: SQLValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: SQLValue] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    row[String(cString: sqlite3_column_name(statement, column))] = value(statement, column)
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        // SQLite copies text and blobs bound with this, so they needn't outlive the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, transient)
            case .blob(let data):
                data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else {
                throw RecordContainerError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func value(_ statement: OpaquePointer, _ column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
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

    func quoted(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
