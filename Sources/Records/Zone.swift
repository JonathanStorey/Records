import CloudKit

/// A record zone, named by a string literal: `let zone: Zone = "Notes"`.
///
/// A literal always names a zone the current user owns. A zone shared with you comes from
/// CloudKit as a `CKRecordZone.ID` and is wrapped with `Zone(_:)`, so owner names never
/// appear in app code.
public struct Zone: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String
    public let ownerName: String

    init(_ name: String, ownerName: String = CKCurrentUserDefaultName) {
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
