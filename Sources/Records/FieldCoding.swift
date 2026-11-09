import CloudKit
import Foundation

/// Converts field values to and from what a `CKRecord` stores. Used by the code `@Record`
/// generates.
///
/// A value CloudKit stores directly, such as a `String`, `Int`, `Date`, `Data`, `CLLocation`, or
/// an array of them, is stored as is. An enum whose raw value CloudKit stores is stored as its raw
/// value. Any other `Codable` value is stored as JSON `Data`. A type that is none of these is a
/// compile error.
///
/// A type can match more than one rule: `String` is Codable, and so is `enum Mood: String, Codable`.
/// Each such pair has its own overload, which Swift prefers because it is more specific, so the
/// most direct storage always wins.
public enum FieldCoding {
    // MARK: Writing

    /// A value CloudKit stores directly.
    public static func value<T: CKRecordValueProtocol>(_ value: T) -> (any CKRecordValueProtocol)? {
        value
    }

    /// A value CloudKit stores directly that is also Codable, such as `String`. Stored directly.
    public static func value<T: CKRecordValueProtocol & Encodable>(_ value: T) -> (any CKRecordValueProtocol)? {
        value
    }

    /// An enum whose raw value CloudKit stores. Stored as its raw value.
    public static func value<T: RawRepresentable>(_ value: T) -> (any CKRecordValueProtocol)?
    where T.RawValue: CKRecordValueProtocol {
        value.rawValue
    }

    /// A Codable enum whose raw value CloudKit stores. Stored as its raw value.
    public static func value<T: RawRepresentable & Encodable>(_ value: T) -> (any CKRecordValueProtocol)?
    where T.RawValue: CKRecordValueProtocol {
        value.rawValue
    }

    /// Any other Codable value. Stored as JSON.
    public static func value<T: Encodable>(_ value: T) -> (any CKRecordValueProtocol)? {
        do {
            return try JSONEncoder.sortedKeys.encode(value)
        } catch {
            assertionFailure("Records couldn't encode '\(T.self)' as JSON: \(error)")
            return nil
        }
    }

    // MARK: Reading

    /// Reads a value CloudKit stores directly.
    public static func reader<T: CKRecordValueProtocol>(_ type: T.Type) -> (Any) throws -> T? {
        { $0 as? T }
    }

    /// Reads a value CloudKit stores directly that is also Codable.
    public static func reader<T: CKRecordValueProtocol & Decodable>(_ type: T.Type) -> (Any) throws -> T? {
        { $0 as? T }
    }

    /// Reads an enum from its raw value.
    public static func reader<T: RawRepresentable>(_ type: T.Type) -> (Any) throws -> T?
    where T.RawValue: CKRecordValueProtocol {
        { ($0 as? T.RawValue).flatMap(T.init(rawValue:)) }
    }

    /// Reads a Codable enum from its raw value.
    public static func reader<T: RawRepresentable & Decodable>(_ type: T.Type) -> (Any) throws -> T?
    where T.RawValue: CKRecordValueProtocol {
        { ($0 as? T.RawValue).flatMap(T.init(rawValue:)) }
    }

    /// Reads any other Codable value from JSON.
    public static func reader<T: Decodable>(_ type: T.Type) -> (Any) throws -> T? {
        { stored in try (stored as? Data).map { try JSONDecoder().decode(T.self, from: $0) } }
    }
}

private extension JSONEncoder {
    /// Sorted keys, so the same value always encodes to the same bytes.
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
