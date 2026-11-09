/// The storage behind a stored property of a `@Record`: its value, and whether it changed since
/// the record was loaded or last saved.
///
/// `@Record` adds it to every `var` except `id` and `@Reference` properties. A record you make
/// starts with every field changed, and a decoded record starts with none. Setting a field marks
/// it changed, even to the same value.
///
/// Two fields are equal when their values are, so a decoded record equals the one that was saved.
public struct Field<Value> {
    /// The property's value.
    public var value: Value {
        didSet { isChanged = true }
    }

    /// Whether the value was set since the record was loaded or last saved.
    public private(set) var isChanged: Bool

    /// A field set in code, which counts as changed.
    public init(_ value: Value) {
        self.value = value
        self.isChanged = true
    }

    /// A field read from storage, which counts as unchanged.
    public init(saved value: Value) {
        self.value = value
        self.isChanged = false
    }

    /// Marks the field saved, so it reports no change until it is set again.
    public mutating func markSaved() {
        isChanged = false
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
