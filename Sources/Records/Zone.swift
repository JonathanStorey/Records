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

    init(_ name: String, ownerName: String = CKCurrentUserDefaultName) {
        precondition(
            Self.isAllowed(name),
            "Zone name '\(name)' is not allowed; Records needs a custom zone such as \"Notes\""
        )
        self.name = name
        self.ownerName = ownerName
    }

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
