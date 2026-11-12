import Foundation

/// A SQL condition and the values bound to its `?` parameters, in order.
struct SQLFilter: Sendable {
    var sql: String
    var values: [SQLValue]

    static let always = SQLFilter(sql: "1", values: [])
    static let never = SQLFilter(sql: "0", values: [])
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
/// part of a predicate SQL can't express (a string `contains`, a computed property) only widens
/// the query, and never changes the result. `isExact` says whether the SQL alone decides the
/// result.
///
/// A path into linked records, such as `$0.album?.artist?.name`, becomes an `EXISTS` over the
/// links and the linked table, one level per hop. Each level is its own translator, whose input
/// is the closure variable of that hop and whose columns are qualified by that level's alias.
struct PredicateTranslator {
    /// How this level's columns are qualified: the quoted table at the top, an alias below.
    let table: String
    /// How many hops below the predicate's input this level is.
    let depth: Int
    /// The variable whose key paths read this level's record.
    var input: PredicateExpressions.VariableID?
    /// Each stored property's column and storage kind, by key path.
    let columns: [AnyKeyPath: Column]
    /// Each reference's links, by key path.
    let links: [AnyKeyPath: Link]

    struct Column {
        let name: String
        /// The column qualified by its level, ready for SQL.
        let sql: String
        let kind: FieldKind
    }

    /// The links a reference reads: those whose `source` is `source` and whose `ownName` column
    /// holds this level's record name. `otherName` holds the other record's name, and `target`
    /// is the other record's type.
    struct Link {
        let source: String
        let ownName: String
        let otherName: String
        let isToMany: Bool
        let holdsIDs: Bool
        let target: any Record.Type
    }

    init<R: Record>(for type: R.Type) {
        self.init(for: type, table: quoted(R.recordType), depth: 0, input: nil)
    }

    private init<R: Record>(for type: R.Type, table: String, depth: Int, input: PredicateExpressions.VariableID?) {
        self.table = table
        self.depth = depth
        self.input = input

        let kinds = Dictionary(uniqueKeysWithValues: R.schema.fields.map { ($0.key, $0.kind) })
        let references = Dictionary(R.schema.references.map { ($0.property, $0) }, uniquingKeysWith: { first, _ in first })
        var columns: [AnyKeyPath: Column] = [:]
        var links: [AnyKeyPath: Link] = [:]
        for (keyPath, name) in R.keyPaths {
            let kind: FieldKind? = name == "_name" ? .text : kinds[name]
            if let reference = references[name] {
                links[keyPath] = Link(reference, of: R.recordType)
            } else if let kind {
                columns[keyPath] = Column(name: name, sql: "\(table).\(quoted(name))", kind: kind)
            }
        }
        self.columns = columns
        self.links = links
    }

    /// The SQL that `predicate` implies, and whether it is exact, or `nil` when no part of it
    /// can be expressed.
    func translate<R>(_ predicate: Predicate<R>) -> (filter: SQLFilter, isExact: Bool)? {
        guard let expression = predicate.expression as? any SQLPredicateExpression else { return nil }
        var translator = self
        translator.input = predicate.variable.key
        if let exact = expression.condition(exact: true, translator) { return (exact, true) }
        return expression.condition(exact: false, translator).map { ($0, false) }
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
            terms.append("\(column.sql) \(descriptor.order == .forward ? "ASC" : "DESC")")
        }
        return (terms + ["\(table).\"_name\" ASC"]).joined(separator: ", ")
    }

    /// What `keyPath` reads, when its root is this level's input.
    func operand(for keyPath: AnyKeyPath, root: Any) -> SQLOperand? {
        guard let input, (root as? any PredicateVariable)?.variableKey == input else { return nil }
        if let column = columns[keyPath] { return .column(column) }
        return links[keyPath].map(SQLOperand.link)
    }

    /// The condition on `link`'s links from this level's record, without the closing `)`.
    private func linkCondition(_ link: Link, alias: String) -> String {
        """
        \(alias)."_zoneName" = \(table)."_zoneName" AND \(alias)."_zoneOwner" = \(table)."_zoneOwner" \
        AND \(alias)."_isCurrent" = 1 AND \(alias)."_deleted" = 0 \
        AND \(alias)."source" = ? AND \(alias).\(quoted(link.ownName)) = \(table)."_name"
        """
    }

    /// Whether this level's record has a link of `link`, to `other` when given. For a
    /// reference that holds IDs, which holds whatever its links name.
    func exists(_ link: Link, to other: SQLValue? = nil) -> SQLFilter {
        let alias = quoted("l\(depth + 1)")
        var sql = "EXISTS (SELECT 1 FROM \(quoted(RecordLink.recordType)) AS \(alias) WHERE \(linkCondition(link, alias: alias))"
        var values: [SQLValue] = [.text(link.source)]
        if let other {
            sql += " AND \(alias).\(quoted(link.otherName)) = ?"
            values.append(other)
        }
        return SQLFilter(sql: sql + ")", values: values)
    }

    /// The level below this one, for the records `link` reaches, read through `variable`.
    func level(below link: Link, variable: PredicateExpressions.VariableID?) -> PredicateTranslator {
        func make<T: Record>(_ type: T.Type) -> PredicateTranslator {
            PredicateTranslator(for: type, table: quoted("t\(depth + 1)"), depth: depth + 1, input: variable)
        }
        return make(link.target)
    }

    /// Whether this level's record has a link of `link` to a saved record that meets `inner`,
    /// written for the level below. For a reference that holds records, which holds only the
    /// targets that are present.
    func reaches(_ link: Link, below: PredicateTranslator, where inner: SQLFilter) -> SQLFilter? {
        guard !link.holdsIDs else { return nil }
        let alias = quoted("l\(depth + 1)")
        let target = below.table
        let sql = """
            EXISTS (SELECT 1 FROM \(quoted(RecordLink.recordType)) AS \(alias) \
            JOIN \(quoted(link.target.recordType)) AS \(target) ON \(target)."_zoneName" = \(alias)."_zoneName" \
            AND \(target)."_zoneOwner" = \(alias)."_zoneOwner" AND \(target)."_name" = \(alias).\(quoted(link.otherName)) \
            AND \(target)."_isCurrent" = 1 AND \(target)."_deleted" = 0 \
            WHERE \(linkCondition(link, alias: alias)) AND \(inner.sql))
            """
        return SQLFilter(sql: sql, values: [.text(link.source)] + inner.values)
    }
}

extension PredicateTranslator.Link {
    /// The links `reference`, declared by `owner`, reads.
    init(_ reference: ReferenceSchema, of owner: String) {
        if let ownerProperty = reference.inverseOf {
            // A `from:` side reads the owner's links from the target end.
            self.init(
                source: RecordLink.source(type: reference.target.recordType, property: ownerProperty),
                ownName: "targetName", otherName: "sourceName",
                isToMany: reference.isToMany, holdsIDs: true, target: reference.target
            )
        } else {
            self.init(
                source: RecordLink.source(type: owner, property: reference.property),
                ownName: "sourceName", otherName: "targetName",
                isToMany: reference.isToMany, holdsIDs: false, target: reference.target
            )
        }
    }
}

// MARK: - Operands

/// One side of a comparison.
indirect enum SQLOperand {
    case column(PredicateTranslator.Column)
    /// A reference. One that holds IDs compares with IDs, and one that holds a record with `nil`.
    case link(PredicateTranslator.Link)
    case value(SQLValue)
    /// `operand` read on the record a to-one reference reaches, as in `$0.artist?.name`.
    case reached(PredicateTranslator.Link, below: PredicateTranslator, SQLOperand)
    /// A Boolean expression on the record a to-one reference reaches, as in
    /// `$0.album?.tracks.contains { ... }`, which holds `nil` without one.
    case test(Test)

    /// A Boolean expression, kept unwritten until it is known whether it must be exact.
    struct Test {
        let condition: (_ exact: Bool) -> SQLFilter?
    }
}

/// A predicate expression that can be written as SQL.
protocol SQLPredicateExpression {
    /// A SQL condition for a Boolean expression. With `exact`, the condition holds exactly when
    /// the expression is true. Without it, the condition only needs to hold whenever the
    /// expression is true.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter?
    /// The expression as an operand, when it is a stored property, a reference, a constant, or
    /// one of those on a linked record.
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

/// A predicate variable, such as the `$0` in `#Predicate { $0.title == "A" }`.
protocol PredicateVariable {
    var variableKey: PredicateExpressions.VariableID { get }
}

extension PredicateExpressions.Variable: PredicateVariable {
    var variableKey: PredicateExpressions.VariableID { key }
}

extension PredicateExpressions.KeyPath: SQLPredicateExpression {
    func operand(_ translator: PredicateTranslator) -> SQLOperand? {
        translator.operand(for: keyPath, root: root)
    }

    /// A Boolean property on its own, as in `#Predicate { $0.isDone }`.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard Output.self == Bool.self, case .column(let column)? = operand(translator) else { return nil }
        return SQLFilter(sql: "(\(column.sql) IS 1)", values: [])
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

extension PredicateExpressions.OptionalFlatMap: SQLPredicateExpression {
    /// `$0.artist?.name`: the transform read on the record a to-one reference reaches.
    func operand(_ translator: PredicateTranslator) -> SQLOperand? {
        guard let wrapped = sqlOperand(wrapped, translator) else { return nil }
        return through(wrapped, translator)
    }

    private func through(_ wrapped: SQLOperand, _ translator: PredicateTranslator) -> SQLOperand? {
        switch wrapped {
        case .link(let link) where !link.isToMany && !link.holdsIDs:
            let below = translator.level(below: link, variable: variable.key)
            if let inner = sqlOperand(transform, below) {
                return .reached(link, below: below, inner)
            }
            let transform = transform
            return .reached(link, below: below, .test(SQLOperand.Test { exact in
                sqlCondition(transform, exact: exact, below)
            }))
        case .reached(let link, let below, let inner):
            // `$0.album?.artist?.name`: the wrapped value already reaches a record.
            return through(inner, below).map { .reached(link, below: below, $0) }
        default:
            return nil
        }
    }
}

extension PredicateExpressions.NilCoalesce: SQLPredicateExpression {
    /// `$0.album?.tracks.contains { ... } ?? false`.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard let operand = sqlOperand(lhs, translator), case .value(.integer(let fallback))? = sqlOperand(rhs, translator)
        else { return nil }
        let isTrue = operandComparison(operand, .equal, .integer(1), exact: exact, translator)
        guard fallback == 1 else { return isTrue }
        guard let isNil = operandComparison(operand, .equal, .null, exact: exact, translator), let isTrue else { return nil }
        return SQLFilter(sql: "(\(isTrue.sql) OR \(isNil.sql))", values: isTrue.values + isNil.values)
    }
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
        // Only an exact condition can be negated.
        guard let inner = sqlCondition(wrapped, exact: true, translator) else { return nil }
        return negated(inner)
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
        guard !conditions.isEmpty else { return .never }
        return SQLFilter(
            sql: "(" + conditions.map(\.sql).joined(separator: " OR ") + ")",
            values: conditions.flatMap(\.values)
        )
    }
}

extension PredicateExpressions.SequenceContainsWhere: SQLPredicateExpression {
    /// `$0.tracks.contains { $0.title == "Bloom" }`: some linked record meets the test.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard case .link(let link)? = sqlOperand(sequence, translator), link.isToMany, !link.holdsIDs else { return nil }
        let below = translator.level(below: link, variable: variable.key)
        // Without a test SQL can write, any linked record lets the row through.
        guard let inner = sqlCondition(test, exact: exact, below) ?? (exact ? nil : .always) else { return nil }
        return translator.reaches(link, below: below, where: inner)
    }
}

extension PredicateExpressions.SequenceAllSatisfy: SQLPredicateExpression {
    /// `$0.tracks.allSatisfy { $0.year > 1990 }`: no linked record fails the test.
    func condition(exact: Bool, _ translator: PredicateTranslator) -> SQLFilter? {
        guard case .link(let link)? = sqlOperand(sequence, translator), link.isToMany, !link.holdsIDs else { return nil }
        let below = translator.level(below: link, variable: variable.key)
        guard let inner = sqlCondition(test, exact: true, below),
              let failing = translator.reaches(link, below: below, where: negated(inner))
        else { return nil }
        return negated(failing)
    }
}

/// A constant in a predicate, read without knowing its type.
protocol ConstantExpression {
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

/// `lhs <comparator> rhs` when one side is an operand and the other a constant, or both are
/// integer properties of the same level.
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
        return SQLFilter(sql: "(\(left.sql) \(comparator.symbol) \(right.sql))", values: [])
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

    case .link(let link) where link.holdsIDs:
        // A to-one ID reference holds the ID its link names, or `nil` without one.
        guard !link.isToMany else { return nil }
        switch (comparator, value) {
        case (.equal, .text): return translator.exists(link, to: value)
        case (.notEqual, .text): return negated(translator.exists(link, to: value))
        case (.equal, .null): return negated(translator.exists(link))
        case (.notEqual, .null): return translator.exists(link)
        default: return nil
        }

    case .link(let link):
        // A to-one record reference holds its target when the target is present.
        guard !link.isToMany, value == .null else { return nil }
        let below = translator.level(below: link, variable: nil)
        guard let present = translator.reaches(link, below: below, where: .always) else { return nil }
        switch comparator {
        case .equal: return negated(present)
        case .notEqual: return present
        default: return nil
        }

    case .reached(let link, let below, let inner):
        // Swift compares `nil` when the record isn't reached. So `== value` needs a reached
        // record that matches, and `!= value` needs no reached record that doesn't.
        let (positive, innerComparator): (Bool, SQLComparator) = switch (comparator, value) {
        case (.equal, .null): (false, .notEqual)
        case (.notEqual, .null): (true, .notEqual)
        case (.notEqual, _): (false, .equal)
        default: (true, comparator)
        }
        if positive {
            guard let inner = operandComparison(inner, innerComparator, value, exact: exact, below) else { return nil }
            return translator.reaches(link, below: below, where: inner)
        }
        guard let inner = operandComparison(inner, innerComparator, value, exact: true, below),
              let reached = translator.reaches(link, below: below, where: inner)
        else { return nil }
        return negated(reached)

    case .test(let test):
        // A Boolean expression, compared with `true`, `false`, or `nil`. Reached, it is never nil.
        switch (comparator, value) {
        case (.equal, .integer(1)), (.notEqual, .integer(0)): return test.condition(exact)
        case (.equal, .integer(0)), (.notEqual, .integer(1)): return test.condition(true).map(negated)
        case (.equal, .null): return .never
        case (.notEqual, .null): return .always
        default: return nil
        }

    case .value:
        return nil
    }
}

/// `NOT filter`. A condition is NULL only where the Swift expression is false, so NULL counts
/// as false before it is negated.
private func negated(_ filter: SQLFilter) -> SQLFilter {
    SQLFilter(sql: "(NOT COALESCE(\(filter.sql), 0))", values: filter.values)
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
    func comparison(_ comparator: SQLComparator, _ value: SQLValue, exact: Bool) -> SQLFilter? {
        let column = sql
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
        case (.integer, .integer), (.real, .integer), (.real, .real), (.date, .real):
            return filter("(\(column) \(comparator.symbol) ?)", [value], isExact: true)
        case (.text, .text(let string)) where !comparator.isOrdered:
            // Swift orders strings by Unicode rules SQLite doesn't follow, so only equality is used.
            if isRecordName { return filter("(\(column) \(comparator.symbol) ?)", [value], isExact: true) }
            let normalized = SQLValue.text(string.precomposedStringWithCanonicalMapping)
            return filter("(\(column) \(comparator.symbol) ? OR \(column) \(beyondASCII))", [normalized], isExact: false)
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
    case let date as Date: return .real(date.timeIntervalSinceReferenceDate)
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
