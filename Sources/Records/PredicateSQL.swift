import Foundation

/// A SQL condition and the values bound to its `?` parameters, in order.
struct SQLFilter: Sendable {
    var sql: String
    var values: [SQLValue]
}

/// The order and range of rows a query reads.
struct SQLPage: Sendable {
    /// The `ORDER BY` list.
    var orderBy: String
    /// The most rows to read, or `nil` for every row.
    var limit: Int?
    /// How many rows to skip first.
    var offset: Int
}

/// Turns a `Predicate` into SQL a row must meet to match it.
///
/// The SQL is a necessary condition, not always an exact one: every record that matches the
/// predicate meets it, and `fetch` still evaluates the predicate on what the query returns. So a
/// part of a predicate SQL can't express (a string `contains`, a computed property, a key path
/// through a reference) only widens the query, and never changes the result. `isExact` says
/// whether the SQL alone decides the result.
struct PredicateTranslator {
    /// The quoted table of the predicate's input, which link conditions name.
    let table: String
    /// Each stored property's column and storage kind, by key path.
    let columns: [AnyKeyPath: Column]
    /// Each reference's links, by key path.
    let links: [AnyKeyPath: Link]

    struct Column {
        let name: String
        let kind: FieldKind
    }

    /// The links a reference reads: those whose `source` is `source` and whose `ownName` column
    /// holds the input record's name. `otherName` holds the other record's name.
    struct Link {
        let source: String
        let ownName: String
        let otherName: String
        let isToMany: Bool
        let holdsIDs: Bool
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
        table = quoted(R.recordType)

        let references = Dictionary(R.schema.references.map { ($0.property, $0) }, uniquingKeysWith: { first, _ in first })
        var links: [AnyKeyPath: Link] = [:]
        for (keyPath, property) in R.referenceKeyPaths {
            guard let reference = references[property] else { continue }
            if let owner = reference.inverseOf {
                // A `from:` side reads the owner's links from the target end.
                links[keyPath] = Link(
                    source: RecordLink.source(type: reference.target.recordType, property: owner),
                    ownName: "targetName", otherName: "sourceName",
                    isToMany: reference.isToMany, holdsIDs: reference.holdsIDs
                )
            } else {
                links[keyPath] = Link(
                    source: RecordLink.source(type: R.recordType, property: property),
                    ownName: "sourceName", otherName: "targetName",
                    isToMany: reference.isToMany, holdsIDs: reference.holdsIDs
                )
            }
        }
        self.links = links
    }

    /// The SQL that `predicate` implies, and whether it is exact, or `nil` when no part of it
    /// can be expressed.
    func translate<R>(_ predicate: Predicate<R>) -> (filter: SQLFilter, isExact: Bool)? {
        guard let expression = predicate.expression as? any SQLPredicateExpression else { return nil }
        if let exact = expression.condition(exact: true, self) { return (exact, true) }
        return expression.condition(exact: false, self).map { ($0, false) }
    }

    /// An `ORDER BY` list that sorts rows as `sortBy` sorts records, or `nil` when SQL can't.
    ///
    /// Only numbers and dates sort the same in SQL and Swift: strings sort by Unicode rules
    /// SQLite doesn't follow, and an enum by its own `<`. `nil` sorts first going forward in
    /// both. The record name comes last, so equal records keep one order from query to query.
    func orderBy<R>(_ sortBy: [SortDescriptor<R>]) -> String? {
        var terms: [String] = []
        for descriptor in sortBy {
            guard let keyPath = descriptor.keyPath,
                  let column = columns[keyPath],
                  [.integer, .real, .date].contains(column.kind),
                  sortsAsStored(type(of: keyPath).valueType)
            else { return nil }
            terms.append("\(quoted(column.name)) \(descriptor.order == .forward ? "ASC" : "DESC")")
        }
        return (terms + [#""_name" ASC"#]).joined(separator: ", ")
    }

    /// What `keyPath` reads, when it reads a stored property or reference of the predicate's
    /// input.
    func operand(for keyPath: AnyKeyPath, rootIsInput: Bool) -> SQLOperand? {
        guard rootIsInput else { return nil }
        if let column = columns[keyPath] { return .column(column) }
        return links[keyPath].map(SQLOperand.link)
    }

    /// Whether the input record has a link of `link`, to `other` when given.
    func exists(_ link: Link, to other: SQLValue? = nil) -> SQLFilter {
        let alias = "\"link\""
        var sql = """
            EXISTS (SELECT 1 FROM \(quoted(RecordLink.recordType)) AS \(alias) \
            WHERE \(alias)."_zoneName" = \(table)."_zoneName" AND \(alias)."_zoneOwner" = \(table)."_zoneOwner" \
            AND \(alias)."_isCurrent" = 1 AND \(alias)."_deleted" = 0 \
            AND \(alias)."source" = ? AND \(alias).\(quoted(link.ownName)) = \(table)."_name"
            """
        var values: [SQLValue] = [.text(link.source)]
        if let other {
            sql += " AND \(alias).\(quoted(link.otherName)) = ?"
            values.append(other)
        }
        return SQLFilter(sql: sql + ")", values: values)
    }
}

// MARK: - Operands

/// One side of a comparison.
enum SQLOperand {
    case column(PredicateTranslator.Column)
    case link(PredicateTranslator.Link)
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
        translator.operand(for: keyPath, rootIsInput: root is PredicateInput)
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
    /// `[a, b].contains($0.property)`, or `$0.targetIDs.contains(id)`.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        if case .link(let link)? = sqlOperand(sequence, translator) {
            guard link.isToMany, link.holdsIDs, case .value(.text(let id))? = sqlOperand(element, translator) else { return nil }
            return translator.exists(link, to: .text(id))
        }
        guard let operand = sqlOperand(element, translator),
              let constant = sequence as? any ConstantExpression,
              let elements = constant.anyValue as? any Sequence
        else { return nil }
        var conditions: [SQLFilter] = []
        for element in elements {
            guard let value = sqlValue(of: element),
                  let condition = operandComparison(operand, .equal, value, exact: exact, translator)
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

/// `lhs <comparator> rhs` when one side is a stored property or ID reference and the other a
/// constant, or both are integer properties.
private func comparison(
    _ comparator: SQLComparator, _ lhs: Any, _ rhs: Any, exact: Bool, _ translator: PredicateTranslator
) -> SQLFilter? {
    switch (sqlOperand(lhs, translator), sqlOperand(rhs, translator)) {
    case let (operand?, .value(value)?):
        return operandComparison(operand, comparator, value, exact: exact, translator)
    case let (.value(value)?, operand?):
        return operandComparison(operand, comparator.reversed, value, exact: exact, translator)
    case let (.column(left)?, .column(right)?) where left.kind == .integer && right.kind == .integer:
        // Only integers compare in SQL exactly as in Swift, column against column.
        return SQLFilter(sql: "(\(quoted(left.name)) \(comparator.symbol) \(quoted(right.name)))", values: [])
    default:
        return nil
    }
}

/// `operand <comparator> value`.
private func operandComparison(
    _ operand: SQLOperand, _ comparator: SQLComparator, _ value: SQLValue, exact: Bool, _ translator: PredicateTranslator
) -> SQLFilter? {
    switch operand {
    case .column(let column):
        return column.comparison(comparator, value, exact: exact)
    case .link(let link):
        // A to-one ID reference holds the ID its link names, or `nil` without one.
        guard !link.isToMany, link.holdsIDs else { return nil }
        switch (comparator, value) {
        case (.equal, .text): return translator.exists(link, to: value)
        case (.notEqual, .text): return negated(translator.exists(link, to: value))
        case (.equal, .null): return negated(translator.exists(link))
        case (.notEqual, .null): return translator.exists(link)
        default: return nil
        }
    case .value:
        return nil
    }
}

private func negated(_ filter: SQLFilter) -> SQLFilter {
    SQLFilter(sql: "(NOT \(filter.sql))", values: filter.values)
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

/// Whether values of `type` sort in Swift as their stored column does in SQL.
private func sortsAsStored(_ type: Any.Type) -> Bool {
    if let optional = type as? any SortableOptional.Type { return sortsAsStored(optional.wrappedType) }
    return type is any BinaryInteger.Type || type == Double.self || type == Float.self || type == Date.self
}

private protocol SortableOptional {
    static var wrappedType: Any.Type { get }
}

extension Optional: SortableOptional {
    static var wrappedType: Any.Type { Wrapped.self }
}
