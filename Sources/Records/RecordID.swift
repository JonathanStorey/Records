import Foundation

/// The ID of a record of type `R`, written `Album.ID`. `@Record` gives a struct one by default,
/// as `var id = Album.ID()`.
///
/// It is a UUID, so it is the record's name in CloudKit, but its type names its record, so an
/// album's ID can't be passed where a track's is expected.
///
/// A new ID is a version 7 UUID that leads with the time it was made, counted the way `Date`
/// counts, from the start of 2001. IDs made in order sort in that order, even within the same
/// instant, and `date` reads the time back.
public struct RecordID<R>: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// The UUID.
    public let rawValue: UUID

    /// A new ID, made now.
    public init() {
        rawValue = Self.clock.next()
    }

    /// The ID `uuid`, such as one from another system.
    public init(_ uuid: UUID) {
        rawValue = uuid
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// The UUID.
    public var uuid: UUID { rawValue }

    /// When the ID was made, or `nil` for an ID `init()` didn't make.
    public var date: Date? {
        let bytes = rawValue.uuid
        guard bytes.6 >> 4 == 7 else { return nil }
        let milliseconds = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let time = milliseconds << 12 | UInt64(bytes.6 & 0x0F) << 8 | UInt64(bytes.7)
        return Date(timeIntervalSinceReferenceDate: Double(time) / Self.ticksPerSecond)
    }

    public var description: String { rawValue.uuidString }

    /// In the order the IDs were made, which is the order of their strings.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The time field's resolution: 1/4096 of a millisecond, which RFC 9562 allows in place of the
    /// 12 random bits after the version.
    private static var ticksPerSecond: Double { 1000 * 4096 }

    /// Every type's IDs share one clock, so no two are ever made with the same time.
    private static var clock: RecordIDClock { RecordIDClock.shared }
}

/// Makes version 7 UUIDs whose 60 bits of time always increase.
private final class RecordIDClock: @unchecked Sendable {
    static let shared = RecordIDClock()
    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UUID {
        let now = UInt64(max(0, Date().timeIntervalSinceReferenceDate) * 1000 * 4096)
        let time = lock.withLock {
            // Two IDs in the same tick, or a clock set back, still sort in the order made.
            last = max(now, last + 1)
            return last
        }
        var random = SystemRandomNumberGenerator()
        let tail = random.next() as UInt64
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: time >> 52), UInt8(truncatingIfNeeded: time >> 44),
            UInt8(truncatingIfNeeded: time >> 36), UInt8(truncatingIfNeeded: time >> 28),
            UInt8(truncatingIfNeeded: time >> 20), UInt8(truncatingIfNeeded: time >> 12),
            0x70 | UInt8(truncatingIfNeeded: time >> 8) & 0x0F, UInt8(truncatingIfNeeded: time),
            0x80 | UInt8(truncatingIfNeeded: tail >> 56) & 0x3F, UInt8(truncatingIfNeeded: tail >> 48),
            UInt8(truncatingIfNeeded: tail >> 40), UInt8(truncatingIfNeeded: tail >> 32),
            UInt8(truncatingIfNeeded: tail >> 24), UInt8(truncatingIfNeeded: tail >> 16),
            UInt8(truncatingIfNeeded: tail >> 8), UInt8(truncatingIfNeeded: tail)
        ))
    }
}

/// A record ID of any type, for code that handles records of any type.
protocol AnyRecordID {
    var uuid: UUID { get }
}

extension RecordID: AnyRecordID {
    /// The UUID as a string, which is the record's name.
    var uuidString: String { rawValue.uuidString }
}

extension Record {
    /// The `id` as a UUID, which reads on a record of any type.
    var uuid: UUID { id.rawValue }
}
