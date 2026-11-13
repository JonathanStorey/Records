import Foundation

/// The ID of a record of type `R`, written `Album.ID`. `@Record` gives a struct one by default,
/// as `var id = Album.ID()`.
///
/// It is a UUID, so it is the record's name in CloudKit, but its type names its record, so an
/// album's ID can't be passed where a track's is expected.
///
/// A new ID is a version 7 UUID that holds the exact `Date` it was made, so IDs sort in the order
/// they were made, even within the same instant.
public struct RecordID<R>: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The UUID.
    public let rawValue: UUID

    /// A new ID, made now.
    public init() {
        rawValue = TimestampClock.shared.next()
    }

    /// The ID `rawValue`, such as a UUID from another system.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    /// In the order the IDs were made: byte by byte, which is also the order of their strings.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        withUnsafeBytes(of: lhs.rawValue.uuid) { a in
            withUnsafeBytes(of: rhs.rawValue.uuid) { b in a.lexicographicallyPrecedes(b) }
        }
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension RecordID {
    /// The UUID as a string, which is the record's name.
    var uuidString: String { rawValue.uuidString }
}

extension Record {
    /// The `id` as a UUID, which reads on a record of any type.
    var uuid: UUID { id.rawValue }
}
