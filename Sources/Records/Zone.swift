import CloudKit

/// A record zone, named by a string literal: `let zone: Zone = "Notes"`.
///
/// The owner defaults to the current user. Records in a zone shared with you use the
/// sharer's owner name.
public struct Zone: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    public let ownerName: String

    public init(_ name: String, ownerName: String = CKCurrentUserDefaultName) {
        self.name = name
        self.ownerName = ownerName
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }

    public init(_ zoneID: CKRecordZone.ID) {
        self.init(zoneID.zoneName, ownerName: zoneID.ownerName)
    }

    /// The CloudKit zone ID.
    public var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: ownerName)
    }

    public var description: String { name }
}
