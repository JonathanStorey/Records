import CloudKit
import Foundation

/// Converts field values to and from what a `CKRecord` stores. Used by the code `@Record`
/// generates.
///
/// A value CloudKit stores directly, such as a `String`, `Int`, `Date`, `Data`, or an array of
/// them, is stored as is. An enum with such a raw value is stored as its raw value. Any other
/// `Codable` value is stored as JSON `Data`.
public enum FieldCoding {
    /// What to store for `value`, or `nil` to clear the field when it is `nil`.
    public static func value<T>(_ value: T) -> (any CKRecordValueProtocol)? {
        // An optional field that is `nil` clears the field.
        if case Optional<Any>.none = value as Any {
            return nil
        }
        if let native = value as? any CKRecordValueProtocol {
            return native
        }
        if let enumValue = value as? any RawRepresentable,
           let raw = enumValue.rawValue as? any CKRecordValueProtocol {
            return raw
        }
        if let encodable = value as? any Encodable {
            do {
                return try JSONEncoder.sortedKeys.encode(encodable)
            } catch {
                assertionFailure("Records couldn't encode '\(T.self)' as JSON: \(error)")
                return nil
            }
        }
        assertionFailure("Records can't store '\(T.self)'; make it Codable or use a type CloudKit stores")
        return nil
    }

    /// `stored` read back as `T`, or `nil` when it can't be.
    static func decode<T>(_ type: T.Type, from stored: Any) throws -> T? {
        if let typed = stored as? T {
            return typed
        }
        if let rawType = T.self as? any RawRepresentable.Type, let value = enumValue(rawType, from: stored) {
            return value as? T
        }
        if let decodable = T.self as? any Decodable.Type, let data = stored as? Data {
            return try JSONDecoder().decode(decodable, from: data) as? T
        }
        return nil
    }

    private static func enumValue<R: RawRepresentable>(_ type: R.Type, from stored: Any) -> R? {
        (stored as? R.RawValue).flatMap(R.init(rawValue:))
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

