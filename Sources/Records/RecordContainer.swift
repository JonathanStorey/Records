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
    /// The app can't reach the app group, usually because its entitlements don't list it.
    case appGroupUnavailable(String)
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
        case .appGroupUnavailable(let group):
            "The app group '\(group)' isn't available. Add it to the app's entitlements."
        case .database(let message):
            "The database couldn't open: \(message)"
        }
    }
}

/// Stores `@Record` values on device and keeps them in sync with CloudKit.
///
/// ```swift
/// let container = try RecordContainer(for: Album.self, Artist.self)
/// container.mainContext.insert(album)
/// try container.mainContext.save()
/// ```
///
/// Every type a registered type refers to is registered too, so naming the types an app starts
/// from is enough. Opening checks the types against each other and creates or updates a table
/// for each.
public final class RecordContainer: Sendable {
    /// `Application Support/Records/default.records`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Where the database lives, relative to its folder.
    private static let fileName = "Records/default.records"

    /// The database file in `appGroup`'s shared folder, or the default file without one.
    static func url(appGroup: String?) throws -> URL {
        guard let appGroup else { return defaultURL }
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw RecordContainerError.appGroupUnavailable(appGroup)
        }
        return folder.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Every registered type by record type, including related types and Records' own.
    let types: [CKRecord.RecordType: any Record.Type]
    let database: Database
    /// The zone contexts start in, and the zone `@Recordable` edits in when it isn't given one.
    public let defaultZone: Zone
    private let contexts = Contexts()

    /// Opens a container for `types` and every type they refer to. Pass `appGroup` to keep the
    /// database in that group's shared folder, so the app's extensions and widgets can open it
    /// too. `defaultZone` is the zone contexts start in and `@Recordable` edits in.
    public convenience init(for types: any Record.Type..., appGroup: String? = nil, defaultZone: Zone = .records) throws {
        try self.init(for: types, appGroup: appGroup, defaultZone: defaultZone)
    }

    /// Opens a container for `types` and every type they refer to. Pass `appGroup` to keep the
    /// database in that group's shared folder, so the app's extensions and widgets can open it
    /// too. `defaultZone` is the zone contexts start in and `@Recordable` edits in.
    public convenience init(for types: [any Record.Type], appGroup: String? = nil, defaultZone: Zone = .records) throws {
        try self.init(for: types, url: Self.url(appGroup: appGroup), defaultZone: defaultZone)
    }

    /// A container whose database lives in memory and never syncs, for tests and previews. It
    /// starts empty every time.
    public static func inMemory(for types: any Record.Type..., defaultZone: Zone = .records) throws -> RecordContainer {
        try RecordContainer(for: types, url: nil, defaultZone: defaultZone)
    }

    /// Opens a container whose database is the file at `url`, or in memory when it is `nil`.
    init(for types: [any Record.Type], url: URL?, defaultZone: Zone = .records) throws {
        self.defaultZone = defaultZone
        self.types = try Self.register(types)
        try Self.validate(self.types)
        database = try Database(url: url)
        // A closure, not `\.schema`: a key path to a static member of an existential metatype
        // crashes the Swift 6.1 compiler.
        try database.createTables(for: self.types.values.map { $0.schema })
    }

    /// The context the app's main actor reads and writes records through. The same context
    /// every time, so its `zone` stays set.
    ///
    /// The container keeps its main context, and the context keeps the database, so a context
    /// stays safe to use even after its container is released.
    @MainActor public var mainContext: RecordContext {
        if let context = contexts.main { return context }
        let context = RecordContext(container: self)
        contexts.main = context
        return context
    }

    /// Keeps `context` in the list that `didSave(from:)` refreshes.
    @MainActor func add(_ context: RecordContext) {
        contexts.all.removeAll { $0.context == nil }
        contexts.all.append(WeakContext(context: context))
    }

    /// Rebases every other context after `context` saved, so their pending edits sit on the
    /// records as now saved and their views redraw.
    @MainActor func didSave(from context: RecordContext) {
        contexts.all.removeAll { $0.context == nil }
        for other in contexts.all.compactMap(\.context) where other !== context {
            other.rebase()
        }
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

/// The contexts a container refers to, on the main actor.
@MainActor
private final class Contexts {
    /// Created the first time `mainContext` is read.
    var main: RecordContext?
    /// Every context made from the container, held weakly so a context goes when nothing else
    /// uses it.
    var all: [WeakContext] = []

    nonisolated init() {}
}

/// A context the container refers to without keeping it.
private struct WeakContext {
    weak var context: RecordContext?
}
