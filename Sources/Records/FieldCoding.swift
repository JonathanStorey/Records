import CloudKit
import CoreLocation
import Foundation

/// How one field type is stored in a `CKRecord` and in its SQLite column. Used by the code
/// `@Record` generates, as in `FieldCoding(String.self).decode("title", from: record)`.
///
/// A value CloudKit stores directly, such as a `String`, `Int`, `Date`, `Data`, `CLLocation`, or
/// an array of them, is stored as is. An enum whose raw value CloudKit stores is stored as its raw
/// value. Any other `Codable` value is stored as JSON `Data`. A type that is none of these is a
/// compile error.
///
/// A type can match more than one rule: `String` is Codable, and so is `enum Mood: String, Codable`.
/// Each such pair has its own initializer, which Swift prefers because it is more specific, so the
/// most direct storage always wins.
public struct FieldCoding<Value> {
    /// The kind of SQLite column the field is stored in.
    public let kind: FieldKind
    private let write: (Value) -> (any CKRecordValueProtocol)?
    private let read: (Any) -> Value?

    fileprivate init(kind: FieldKind, write: @escaping (Value) -> (any CKRecordValueProtocol)?, read: @escaping (Any) -> Value?) {
        self.kind = kind
        self.write = write
        self.read = read
    }

    /// A value CloudKit stores directly.
    public init(_ type: Value.Type) where Value: CKRecordValueProtocol {
        self.init(kind: .direct(Value.self), write: { $0 }, read: { $0 as? Value })
    }

    /// A value CloudKit stores directly that is also Codable, such as `String`. Stored directly.
    public init(_ type: Value.Type) where Value: CKRecordValueProtocol & Codable {
        self.init(kind: .direct(Value.self), write: { $0 }, read: { $0 as? Value })
    }

    /// An enum whose raw value CloudKit stores. Stored as its raw value.
    public init(_ type: Value.Type) where Value: RawRepresentable, Value.RawValue: CKRecordValueProtocol {
        self.init(kind: .direct(Value.RawValue.self), write: { $0.rawValue }, read: { ($0 as? Value.RawValue).flatMap(Value.init(rawValue:)) })
    }

    /// A Codable enum whose raw value CloudKit stores. Stored as its raw value.
    public init(_ type: Value.Type) where Value: RawRepresentable & Codable, Value.RawValue: CKRecordValueProtocol {
        self.init(kind: .direct(Value.RawValue.self), write: { $0.rawValue }, read: { ($0 as? Value.RawValue).flatMap(Value.init(rawValue:)) })
    }

    /// Any other Codable value. Stored as JSON.
    public init(_ type: Value.Type) where Value: Codable {
        self.init(
            kind: .bytes,
            write: { value in
                do {
                    return try JSONEncoder.sortedKeys.encode(value)
                } catch {
                    assertionFailure("Records couldn't encode '\(Value.self)' as JSON: \(error)")
                    return nil
                }
            },
            read: { ($0 as? Data).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } }
        )
    }

    /// What a `CKRecord` stores for `value`. `nil` clears the field.
    public func value(_ value: Value?) -> (any CKRecordValueProtocol)? {
        value.flatMap(write)
    }

    /// The value of `key`. Pass `record.encryptedValues` for an `@Encrypted` field.
    public func decode(_ key: String, from record: any CKRecordKeyValueSetting) throws -> Value {
        guard let value = try decodeIfPresent(key, from: record) else {
            throw CKRecordDecodingError.missingField(key)
        }
        return value
    }

    /// The value of `key`, or `nil` when the field is missing. Pass `record.encryptedValues` for
    /// an `@Encrypted` field.
    public func decodeIfPresent(_ key: String, from record: any CKRecordKeyValueSetting) throws -> Value? {
        guard let stored = record.object(forKey: key) else { return nil }
        guard let value = read(stored) else {
            throw CKRecordDecodingError.typeMismatch(field: key)
        }
        return value
    }

    // MARK: Rows

    /// The value of the column `key`.
    public func decode(_ key: String, from row: RecordRow) throws -> Value {
        guard let value = try decodeIfPresent(key, from: row) else {
            throw CKRecordDecodingError.missingField(key)
        }
        return value
    }

    /// The value of the column `key`, or `nil` when it is `NULL`.
    public func decodeIfPresent(_ key: String, from row: RecordRow) throws -> Value? {
        guard let stored = row.values[key], stored != .null else { return nil }
        guard let value = kind.recordValue(stored).flatMap({ read($0) }) else {
            throw CKRecordDecodingError.typeMismatch(field: key)
        }
        return value
    }

    /// Writes `value` to the column `key`. `nil` writes `NULL`.
    public func encode(_ value: Value?, into row: inout RecordRow, forKey key: String) {
        row.values[key] = kind.sqlValue(self.value(value))
    }
}

extension LocationField {
    /// How a `@Location` is stored: as a keyed archive of its `CLLocation`, so every detail is
    /// kept, including how accurate its course and speed are. A location stored as a `CLLocation`
    /// reads too.
    public static var coding: FieldCoding<Stored> {
        FieldCoding(
            kind: .bytes,
            write: { location in
                do {
                    return try NSKeyedArchiver.archivedData(withRootObject: location, requiringSecureCoding: true)
                } catch {
                    assertionFailure("Records couldn't archive a location: \(error)")
                    return nil
                }
            },
            read: { stored in
                if let location = stored as? CLLocation { return location }
                return (stored as? Data).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CLLocation.self, from: $0) }
            }
        )
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
