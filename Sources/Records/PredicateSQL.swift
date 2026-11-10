import Foundation

/// A SQL condition and the values bound to its `?` parameters, in order.
struct SQLFilter: Sendable {
    var sql: String
    var values: [SQLValue]
}

/// Turns a `Predicate` into SQL a row must meet to match it.
///
/// The SQL is a necessary condition, not always an exact one: every record that matches the
/// predicate meets it, and `fetch` still evaluates the predicate on what the query returns. So a
/// part of a predicate SQL can't express (a string `contains`, a computed property, a key path
/// through a reference) only widens the query, and never changes the result. `isExact` says
/// whether the SQL alone decides the result.
struct PredicateTranslator {
    /// Each stored property's column and storage kind, by key path.
    let columns: [AnyKeyPath: Column]

    struct Column {
        let name: String
        let kind: FieldKind
    }

    init<R: Record>(for type: R.Type) {
        let kinds = Dictionary(uniqueKeysWithValues: R.schema.fields.map { ($0.key, $0.kind) })
        var columns: [AnyKeyPath: Column] = [:]
        for (keyPath, name) in R.fieldKeyPaths {
            if name == "_name" {
                columns[keyPath] = Column(name: name, kind: .text)
            } else if let kind = kinds[name] {
                columns[keyPath] = Column(name: name, kind: kind)
            }
        }
        self.columns = columns
    }

    /// The SQL that `predicate` implies, and whether it is exact, or `nil` when no part of it
    /// can be expressed.
    func translate<R>(_ predicate: Predicate<R>) -> (filter: SQLFilter, isExact: Bool)? {
        guard let expression = predicate.expression as? any SQLPredicateExpression else { return nil }
        if let exact = expression.condition(exact: true, self) { return (exact, true) }
        return expression.condition(exact: false, self).map { ($0, false) }
    }

    /// The column `keyPath` reads, when it reads a stored property of the predicate's input.
    func column(for keyPath: AnyKeyPath, rootIsInput: Bool) -> Column? {
        rootIsInput ? columns[keyPath] : nil
    }
}

// MARK: - Operands

/// One side of a comparison.
enum SQLOperand {
    case column(PredicateTranslator.Column)
    case value(SQLValue)
}

/// A predicate expression that can be written as SQL.
protocol SQLPredicateExpression {
    /// A SQL condition for a Boolean expression. With `exact`, the condition holds exactly when
    /// the expression is true. Without it, the condition only needs to hold whenever the
    /// expression is true.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter?
    /// The expression as an operand, when it is a stored property or a constant.
    func operand(_ translator: PredicateTranslator) -> SQLOperand?
}

extension SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? { nil }
    func operand(_ translator: PredicateTranslator) -> SQLOperand? { nil }
}

private func sqlOperand(_ expression: Any, _ translator: PredicateTranslator) -> SQLOperand? {
    (expression as? any SQLPredicateExpression)?.operand(translator)
}

private func sqlCondition(_ expression: Any, exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
    (expression as? any SQLPredicateExpression)?.condition(exact: exact, translator)
}

/// Marks the predicate's input, the `$0` in `#Predicate { $0.title == "A" }`.
private protocol PredicateInput {}
extension PredicateExpressions.Variable: PredicateInput {}

extension PredicateExpressions.KeyPath: SQLPredicateExpression {
    func operand(_ translator: PredicateTranslator) -> SQLOperand? {
        translator.column(for: keyPath, rootIsInput: root is PredicateInput).map(SQLOperand.column)
    }

    /// A Boolean property on its own, as in `#Predicate { $0.isDone }`.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard Output.self == Bool.self, case .column(let column)? = operand(translator) else { return nil }
        return SQLFilter(sql: "(\(quoted(column.name)) IS 1)", values: [])
    }
}

extension PredicateExpressions.Value: SQLPredicateExpression {
    func operand(_ translator: PredicateTranslator) -> SQLOperand? {
        sqlValue(of: value).map(SQLOperand.value)
    }
}

extension PredicateExpressions.NilLiteral: SQLPredicateExpression {
    func operand(_ translator: PredicateTranslator) -> SQLOperand? { .value(.null) }
}

// MARK: - Conditions

extension PredicateExpressions.Equal: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        comparison(.equal, lhs, rhs, exact: exact, translator)
    }
}

extension PredicateExpressions.NotEqual: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        comparison(.notEqual, lhs, rhs, exact: exact, translator)
    }
}

extension PredicateExpressions.Comparison: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        let comparator: SQLComparator? = switch op {
        case .lessThan: .less
        case .lessThanOrEqual: .lessOrEqual
        case .greaterThan: .greater
        case .greaterThanOrEqual: .greaterOrEqual
        @unknown default: nil
        }
        return comparator.flatMap { comparison($0, lhs, rhs, exact: exact, translator) }
    }
}

extension PredicateExpressions.Conjunction: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        let left = sqlCondition(lhs, exact: exact, translator)
        let right = sqlCondition(rhs, exact: exact, translator)
        switch (left, right) {
        case let (left?, right?):
            return SQLFilter(sql: "(\(left.sql) AND \(right.sql))", values: left.values + right.values)
        case let (side?, nil), let (nil, side?):
            // Either side alone still holds whenever both do.
            return exact ? nil : side
        case (nil, nil):
            return nil
        }
    }
}

extension PredicateExpressions.Disjunction: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard let left = sqlCondition(lhs, exact: exact, translator),
              let right = sqlCondition(rhs, exact: exact, translator)
        else { return nil }
        return SQLFilter(sql: "(\(left.sql) OR \(right.sql))", values: left.values + right.values)
    }
}

extension PredicateExpressions.Negation: SQLPredicateExpression {
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        // Only an exact condition can be negated. A condition is NULL only where the Swift
        // expression is false, so NULL counts as false before it is negated.
        guard let inner = sqlCondition(wrapped, exact: true, translator) else { return nil }
        return SQLFilter(sql: "(NOT COALESCE(\(inner.sql), 0))", values: inner.values)
    }
}

extension PredicateExpressions.SequenceContains: SQLPredicateExpression {
    /// `[a, b].contains($0.property)`.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard case .column(let column)? = sqlOperand(element, translator),
              let constant = sequence as? any ConstantExpression,
              let elements = constant.anyValue as? any Sequence
        else { return nil }
        var conditions: [SQLFilter] = []
        for element in elements {
            guard let value = sqlValue(of: element),
                  let condition = column.comparison(.equal, value, exact: exact)
            else { return nil }
            conditions.append(condition)
        }
        guard !conditions.isEmpty else { return SQLFilter(sql: "0", values: []) }
        return SQLFilter(
            sql: "(" + conditions.map(\.sql).joined(separator: " OR ") + ")",
            values: conditions.flatMap(\.values)
        )
    }
}

/// A constant in a predicate, read without knowing its type.
private protocol ConstantExpression {
    var anyValue: Any { get }
}

extension PredicateExpressions.Value: ConstantExpression {
    var anyValue: Any { value }
}

/// How a comparison relates its two sides.
enum SQLComparator {
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual

    /// The same comparison with its sides swapped.
    var reversed: SQLComparator {
        switch self {
        case .equal, .notEqual: self
        case .less: .greater
        case .lessOrEqual: .greaterOrEqual
        case .greater: .less
        case .greaterOrEqual: .lessOrEqual
        }
    }

    var isOrdered: Bool { self != .equal && self != .notEqual }

    var symbol: String {
        switch self {
        case .equal: "IS"
        case .notEqual: "IS NOT"
        case .less: "<"
        case .lessOrEqual: "<="
        case .greater: ">"
        case .greaterOrEqual: ">="
        }
    }
}

/// `lhs <comparator> rhs` when one side is a stored property and the other a constant, or both
/// are integer properties.
private func comparison(
    _ comparator: SQLComparator, _ lhs: Any, _ rhs: Any, exact: Bool, _ translator: PredicateTranslator
) -> SQLFilter? {
    switch (sqlOperand(lhs, translator), sqlOperand(rhs, translator)) {
    case let (.column(column)?, .value(value)?):
        return column.comparison(comparator, value, exact: exact)
    case let (.value(value)?, .column(column)?):
        return column.comparison(comparator.reversed, value, exact: exact)
    case let (.column(left)?, .column(right)?) where left.kind == .integer && right.kind == .integer:
        // Only integers compare in SQL exactly as in Swift, column against column.
        return SQLFilter(sql: "(\(quoted(left.name)) \(comparator.symbol) \(quoted(right.name)))", values: [])
    default:
        return nil
    }
}

/// Matches a string holding any character outside printable ASCII.
private let beyondASCII = "GLOB '*[^ -~]*'"

extension PredicateTranslator.Column {
    /// The record name, which holds a UUID string.
    var isRecordName: Bool { name == "_name" }

    /// `column <comparator> value`, or `nil` when SQL can't give a condition that holds
    /// whenever Swift's comparison does, or an exact one when `exact` asks for it.
    ///
    /// SQL and Swift disagree in a few places, so some comparisons are only necessary:
    /// - Swift strings are equal when canonically equivalent ("é" as one or two scalars). Text
    ///   matches exactly when it is ASCII, so any other text is let through for Swift to decide.
    /// - SQLite stores NaN as NULL, so a NULL real may be NaN rather than `nil`.
    /// - Dates are stored as seconds since 1970, which can round a date to its neighbor, so
    ///   strict bounds are loosened and inequality isn't used.
    func comparison(_ comparator: SQLComparator, _ value: SQLValue, exact: Bool) -> SQLFilter? {
        let column = quoted(name)
        func filter(_ sql: String, _ values: [SQLValue] = [], isExact: Bool) -> SQLFilter? {
            exact && !isExact ? nil : SQLFilter(sql: sql, values: values)
        }

        if value == .null {
            switch comparator {
            case .equal: return filter("(\(column) IS NULL)", isExact: kind != .real)
            case .notEqual: return kind == .real ? nil : filter("(\(column) IS NOT NULL)", isExact: true)
            default: return nil
            }
        }
        switch (kind, value) {
        case (.integer, .integer), (.real, .integer), (.real, .real):
            return filter("(\(column) \(comparator.symbol) ?)", [value], isExact: true)
        case (.text, .text(let string)) where !comparator.isOrdered:
            // Swift orders strings by Unicode rules SQLite doesn't follow, so only equality is used.
            if isRecordName { return filter("(\(column) \(comparator.symbol) ?)", [value], isExact: true) }
            let normalized = SQLValue.text(string.precomposedStringWithCanonicalMapping)
            return filter("(\(column) \(comparator.symbol) ? OR \(column) \(beyondASCII))", [normalized], isExact: false)
        case (.date, .real):
            let symbol: String? = switch comparator {
            case .equal: "IS"
            case .notEqual: nil
            case .less, .lessOrEqual: "<="
            case .greater, .greaterOrEqual: ">="
            }
            return symbol.flatMap { filter("(\(column) \($0) ?)", [value], isExact: false) }
        default:
            return nil
        }
    }
}

/// The column value a predicate constant is stored as, or `nil` when it isn't one SQL can
/// compare.
private func sqlValue(of value: Any) -> SQLValue? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let wrapped = mirror.children.first?.value else { return .null }
        return sqlValue(of: wrapped)
    }
    switch value {
    case let string as String: return .text(string)
    case let bool as Bool: return .integer(bool ? 1 : 0)
    case let number as any BinaryInteger: return Int64(exactly: number).map(SQLValue.integer)
    case let number as Double: return number.isNaN ? nil : .real(number)
    case let number as Float: return number.isNaN ? nil : .real(Double(number))
    case let date as Date: return .real(date.timeIntervalSince1970)
    case let id as UUID: return .text(id.uuidString)
    case let raw as any RawRepresentable: return sqlValue(of: raw.rawValue)
    default: return nil
    }
}

private func quoted(_ name: String) -> String {
    "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
}
