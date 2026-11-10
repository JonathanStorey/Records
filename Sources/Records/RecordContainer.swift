import CloudKit
import Foundation

/// Why a `RecordContainer` couldn't open.
public enum RecordContainerError: Error, Equatable, CustomStringConvertible {
    /// Two types use the same record type.
    case duplicateRecordType(String)
    /// A type uses a record type that Records keeps for itself.
    case reservedRecordType(String)
    /// A field name starts with an underscore, which Records keeps for its own columns.
    case reservedFieldName(recordType: String, field: String)
    /// A `@Reference(from:)` names a property that doesn't point back at its type.
    case invalidInverse(recordType: String, property: String)
    /// SQLite reported an error.
    case database(String)

    public var description: String {
        switch self {
        case .duplicateRecordType(let type):
            "Two types use the record type '\(type)'. Give one a different name with @Record(\"Name\")."
        case .reservedRecordType(let type):
            "'\(type)' is a record type Records uses itself. Choose another name."
        case .reservedFieldName(let type, let field):
            "\(type).\(field) starts with an underscore, which Records keeps for itself. Rename it or use @Renamed."
        case .invalidInverse(let type, let property):
            "\(type).\(property) names a property that doesn't point at \(type)."
        case .database(let message):
            "The database couldn't open: \(message)"
        }
    }
}

/// Stores `@Record` values on device and keeps them in sync with CloudKit.
///
/// ```swift
/// let container = try RecordContainer(for: Album.self, Artist.self)
/// ```
///
/// Every type a registered type refers to is registered too, so naming the types an app starts
/// from is enough. Opening checks the types against each other and creates or updates a table
/// for each.
public final class RecordContainer: Sendable {
    /// Where the container keeps its data and how it syncs.
    public struct Configuration: Sendable {
        /// Where the database lives.
        public enum Storage: Sendable {
            /// A database file at this URL. Its folder is created if needed.
            case file(URL)
            /// A database that lasts as long as the container, for tests and previews.
            case inMemory
        }

        /// Which iCloud container to sync with.
        public enum CloudKit: Sendable {
            /// The app's default container.
            case automatic
            /// The container with this identifier, such as `iCloud.com.example.app`.
            case container(String)
            /// No sync.
            case none
        }

        public var storage: Storage
        public var cloudKit: CloudKit

        public init(storage: Storage = .file(RecordContainer.defaultURL), cloudKit: CloudKit = .automatic) {
            self.storage = storage
            self.cloudKit = cloudKit
        }
    }

    /// `Application Support/Records/default.sqlite`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Records", directoryHint: .isDirectory)
            .appending(path: "default.sqlite", directoryHint: .notDirectory)
    }

    public let configuration: Configuration
    /// Every registered type by record type, including related types and Records' own.
    let types: [CKRecord.RecordType: any Record.Type]
    let database: Database

    /// Opens a container for `types` and every type they refer to.
    public convenience init(for types: any Record.Type..., configuration: Configuration = Configuration()) throws {
        try self.init(for: types, configuration: configuration)
    }

    /// Opens a container for `types` and every type they refer to.
    public init(for types: [any Record.Type], configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        self.types = try Self.register(types)
        try Self.validate(self.types)
        database = try Database(configuration.storage)
        try database.createTables(for: self.types.values.map(\.schema))
    }

    /// The record types this container stores, sorted.
    public var recordTypes: [CKRecord.RecordType] {
        types.keys.sorted()
    }

    // MARK: - Schema

    /// `types`, every type they refer to, and `RecordLink`, by record type.
    private static func register(_ types: [any Record.Type]) throws -> [CKRecord.RecordType: any Record.Type] {
        var registered: [CKRecord.RecordType: any Record.Type] = [:]
        var queue: [any Record.Type] = [RecordLink.self] + types
        while !queue.isEmpty {
            let type = queue.removeFirst()
            let recordType = type.recordType
            if let existing = registered[recordType] {
                guard ObjectIdentifier(existing) == ObjectIdentifier(type) else {
                    throw recordType == RecordLink.recordType
                        ? RecordContainerError.reservedRecordType(recordType)
                        : RecordContainerError.duplicateRecordType(recordType)
                }
                continue
            }
            registered[recordType] = type
            queue += type.schema.references.map(\.target)
        }
        return registered
    }

    /// Checks field names and that each `@Reference(from:)` names a property pointing back.
    private static func validate(_ types: [CKRecord.RecordType: any Record.Type]) throws {
        for (recordType, type) in types {
            let schema = type.schema
            for field in schema.fields where field.key.hasPrefix("_") {
                throw RecordContainerError.reservedFieldName(recordType: recordType, field: field.key)
            }
            for reference in schema.references {
                guard let ownerProperty = reference.inverseOf else { continue }
                let owner = reference.target.schema.references.first { $0.property == ownerProperty }
                guard let owner, !owner.isFrom, owner.target.recordType == recordType else {
                    throw RecordContainerError.invalidInverse(recordType: recordType, property: reference.property)
                }
            }
        }
    }
}
