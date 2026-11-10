import CloudKit

/// A record zone, named by a string literal: `let zone: Zone = "Notes"`.
///
/// A literal always names a zone the current user owns. A zone shared with you comes from
/// CloudKit as a `CKRecordZone.ID` and is wrapped with `Zone(_:)`, so owner names never
/// appear in app code.
///
/// The default zone and other names starting with `_` are not allowed, and stop with a message
/// the first time they are created.
public struct Zone: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    public let ownerName: String
    /// Where the container keeps the zone's records.
    let storage: Storage

    /// Where the container keeps a zone's records.
    enum Storage: Hashable, Sendable {
        /// On device, synced with CloudKit.
        case synced
        /// On device only.
        case local
        /// In memory only, gone when the container is.
        case inMemory
    }

    /// The zone a container uses unless told otherwise, named `Records`.
    public static let records: Zone = "Records"

    /// Records kept on this device only and never synced. A container opened with it doesn't
    /// sync.
    public static let local = Zone(reserved: "_local", storage: .local)

    /// Records kept in memory and never synced, for tests and previews. A container opened with
    /// it starts empty every time.
    public static let inMemory = Zone(reserved: "_inMemory", storage: .inMemory)

    init(_ name: String, ownerName: String = CKCurrentUserDefaultName) {
        precondition(
            Self.isAllowed(name),
            "Zone name '\(name)' is not allowed; Records needs a custom zone such as \"Notes\""
        )
        self.name = name
        self.ownerName = ownerName
        storage = .synced
    }

    /// One of Records' own zones, which never reach CloudKit.
    private init(reserved name: String, storage: Storage) {
        self.name = name
        ownerName = CKCurrentUserDefaultName
        self.storage = storage
    }

    /// Whether the zone's records sync with CloudKit.
    public var isSynced: Bool { storage == .synced }

    public init(stringLiteral name: String) {
        self.init(name)
    }

    public init(_ zoneID: CKRecordZone.ID) {
        self.init(zoneID.zoneName, ownerName: zoneID.ownerName)
    }

    /// Records works only in custom zones. An empty name is invalid, and names starting with `_`
    /// are reserved for CloudKit's own zones, such as `_defaultZone`, which cannot be shared
    /// or tracked for changes.
    static func isAllowed(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_")
    }

    /// The CloudKit zone ID.
    public var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: ownerName)
    }

    public var description: String { name }
}
