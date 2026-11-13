import Foundation
import Synchronization

/// Makes the version 7 UUIDs behind new IDs, from swift-identification's `UUID.timestamp`.
///
/// The 122 bits other than the version and variant hold, in order:
/// - 48 bits: Unix milliseconds, as RFC 9562 requires, so any v7 tool reads the right time.
/// - 14 bits: which tick of `Date`'s own precision, 2⁻²³ seconds, the date falls on within that
///   millisecond, so the exact `Date` comes back.
/// - 60 bits: random.
///
/// Each UUID's date is later than the last one's: a date that repeats, or a clock that steps back,
/// advances by one step of `Date`'s precision. So IDs always sort in the order they were made.
final class TimestampClock: Sendable {
    static let shared = TimestampClock()

    /// The last date stored, in seconds since 2001, always a whole number of ticks.
    private let last = Mutex<Double?>(nil)

    func next(_ date: Date = .now) -> UUID {
        let stored = last.withLock { last in
            var stored = Self.wholeTicks(date.timeIntervalSinceReferenceDate)
            if let previous = last, stored <= previous {
                // One step is the spacing of `Double` values, but never finer than one tick.
                stored = previous + max(previous.ulp, Self.tick)
            }
            last = stored
            return stored
        }
        return Self.uuid(timestamp: Self.timestamp(stored))
    }

    /// The date stored in `uuid`, or `nil` when another generator made it.
    static func date(of uuid: UUID) -> Date? {
        let value = withUnsafeBytes(of: uuid.uuid) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
        guard value >> 76 & 0xF == 7, value >> 62 & 0b11 == 0b10 else { return nil }
        let high: UInt128 = (value >> 80) << 74
        let middle: UInt128 = (value >> 64 & 0xFFF) << 62
        let payload = high | middle | value & mask(62)
        let field = payload >> (payloadBits - timestampBits)
        let milliseconds = Int128(field >> tickIndexBits)
        let tickIndex = Int128(field & mask(tickIndexBits))
        guard firstTick(ofMillisecond: milliseconds) + tickIndex < firstTick(ofMillisecond: milliseconds + 1) else { return nil }
        let ticks = firstTick(ofMillisecond: milliseconds) + tickIndex - referenceOffsetTicks
        return Date(timeIntervalSinceReferenceDate: Double(ticks) * tick)
    }

    // MARK: Layout

    /// One tick, 2⁻²³ seconds: the spacing of `Double` values for dates from 2018 to 2035.
    private static let tick = 0x1p-23
    private static let ticksPerSecondShift = 23
    /// Ticks between 1970 and 2001, the `Date` reference date.
    private static let referenceOffsetTicks = Int128(978_307_200) << ticksPerSecondShift
    private static let maxMilliseconds = Int128(1) << 48 - 1
    private static let tickIndexBits = 14
    private static let timestampBits = 48 + tickIndexBits
    private static let payloadBits = 122

    private static func mask(_ bits: Int) -> UInt128 {
        (1 << bits) - 1
    }

    /// `seconds` rounded down to a whole tick, within the range the timestamp holds.
    private static func wholeTicks(_ seconds: Double) -> Double {
        let earliest = -Double(referenceOffsetTicks >> ticksPerSecondShift)
        let latest = Double(maxMilliseconds) / 1000 + earliest - 1
        return (min(max(seconds, earliest), latest) / tick).rounded(.down) * tick
    }

    /// The first tick at or after the start of a Unix millisecond.
    private static func firstTick(ofMillisecond milliseconds: Int128) -> Int128 {
        ((milliseconds << ticksPerSecondShift) + 999) / 1000
    }

    /// The 62-bit timestamp of a date that is a whole number of ticks since 2001: Unix
    /// milliseconds, then the tick's index within that millisecond, at most 8389, so 14 bits.
    private static func timestamp(_ seconds: Double) -> UInt64 {
        let ticks = Int128(seconds / tick) + referenceOffsetTicks
        let milliseconds = (ticks * 1000) >> ticksPerSecondShift
        let tickIndex = ticks - firstTick(ofMillisecond: milliseconds)
        return UInt64(milliseconds) << tickIndexBits | UInt64(tickIndex)
    }

    /// A version 7 UUID holding `timestamp` and random bits.
    private static func uuid(timestamp: UInt64) -> UUID {
        var generator = SystemRandomNumberGenerator()
        let randomBits = payloadBits - timestampBits
        let payload = UInt128(timestamp) << randomBits | UInt128(generator.next() as UInt64) & mask(randomBits)
        let high: UInt128 = (payload >> 74) << 80 | 0x7 << 76
        let middle: UInt128 = (payload >> 62 & 0xFFF) << 64 | 0b10 << 62
        let value = high | middle | payload & mask(62)
        let byte = { (index: Int) in UInt8(truncatingIfNeeded: value >> (120 - 8 * index)) }
        return UUID(uuid: (
            byte(0), byte(1), byte(2), byte(3), byte(4), byte(5), byte(6), byte(7),
            byte(8), byte(9), byte(10), byte(11), byte(12), byte(13), byte(14), byte(15)
        ))
    }
}
