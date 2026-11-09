import Foundation

/// The storage behind a stored property of a `@Record`: its value, and whether it changed since
/// the record was loaded or last saved.
///
/// `@Record` adds it to every `var` except `id` and `@Reference` properties. A record you make
/// starts with every field changed, and a decoded record starts with none. Setting a field marks
/// it changed, even to the same value, and records when. When two copies change the same field,
/// the store can keep the later edit rather than the later save.
///
/// Two fields are equal when their values are, so a decoded record equals the one that was saved.
public struct Field<Value> {
    /// The property's value.
    public var value: Value {
        didSet { changedAt = Date() }
    }

    /// When the value was last set, or `nil` if it hasn't been since the record was loaded or
    /// last saved. This device's clock, so compare it only with other edits made here.
    public private(set) var changedAt: Date?

    /// Whether the value was set since the record was loaded or last saved.
    public var isChanged: Bool { changedAt != nil }

    /// A field set in code, which counts as changed.
    public init(_ value: Value) {
        self.value = value
        self.changedAt = Date()
    }

    /// A field read from storage, which counts as unchanged.
    public init(saved value: Value) {
        self.value = value
        self.changedAt = nil
    }

    /// Marks the field saved, so it reports no change until it is set again.
    public mutating func markSaved() {
        changedAt = nil
    }
}

extension Field: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }
}

extension Field: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

extension Field: Sendable where Value: Sendable {}
