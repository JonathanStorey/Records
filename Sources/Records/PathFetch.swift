import CloudKit
import Foundation

// Fetching with a predicate that reads through references to records, such as
// `$0.album?.artist?.name == "Nova"`. The database narrows the rows as usual. Swift then checks
// each one with the saved records its paths reach loaded.

/// The references to records a predicate reads through.
struct Traversal {
    /// The references, by the record type that declares them and their property.
    private(set) var references: Set<Reference> = []
    /// The most hops a path can take: each hop reads through a closure variable of its own, so
    /// the predicate's variables beyond its input bound it.
    private(set) var hops = 0

    struct Reference: Hashable {
        let recordType: CKRecord.RecordType
        let property: String
    }

    var isEmpty: Bool { references.isEmpty }

    init(_ expression: Any) {
        var variables: Set<PredicateExpressions.VariableID> = []
        walk(expression, variables: &variables, depth: 0)
        hops = max(variables.count - 1, 1)
    }

    private mutating func walk(_ value: Any, variables: inout Set<PredicateExpressions.VariableID>, depth: Int) {
        guard depth < 100, !(value is any ConstantExpression) else { return }
        if let keyPath = value as? AnyKeyPath {
            if let root = type(of: keyPath).rootType as? any Record.Type,
               let reference = root.recordReference(for: keyPath) {
                references.insert(Reference(recordType: root.recordType, property: reference.property))
            }
            return
        }
        if let variable = value as? any PredicateVariable {
            variables.insert(variable.variableKey)
            return
        }
        for child in Mirror(reflecting: value).children {
            walk(child.value, variables: &variables, depth: depth + 1)
        }
    }

    func contains(_ recordType: CKRecord.RecordType, _ property: String) -> Bool {
        references.contains(Reference(recordType: recordType, property: property))
    }
}

extension Record {
    /// The reference `keyPath` reads, when it is one of this type's references that hold records.
    static func recordReference(for keyPath: AnyKeyPath) -> ReferenceSchema? {
        guard let partial = keyPath as? PartialKeyPath<Self>, let property = keyPaths[partial] else { return nil }
        return schema.references.first { $0.property == property && !$0.isFrom }
    }
}

/// The records a predicate's paths reach, with every link that touches them.
private struct Graph {
    /// The zone every record in the graph is read from.
    let zone: Zone
    var records = RecordGraph()
    /// The names of the records whose links are loaded.
    var linksLoaded: Set<String> = []

    init(zone: Zone) {
        self.zone = zone
    }

    subscript(key: RecordKey) -> RecordRow? {
        get { records[key.recordType, key.name] }
        set { records[key.recordType, key.name] = newValue }
    }

    /// The links that name the record named `name`.
    func links(naming name: String) -> [RecordLink] {
        records.linksByName[name] ?? []
    }
}

private extension RecordLink {
    /// The record name the link holds in `column`, `sourceName` or `targetName`.
    func name(in column: String) -> String? {
        column == "sourceName" ? sourceName : column == "targetName" ? targetName : nil
    }
}

/// What loading a path needs to know about one record type, read from its schema once.
private struct PathInfo {
    /// The traversed references the type declares, with the type each one reaches.
    let traversed: [(link: PredicateTranslator.Link, target: CKRecord.RecordType)]
    /// The `source` of every link the type reads from the target end, for its `from:` sides.
    let inverseSources: Set<String>
}

/// `PathInfo` by record type, filled as types come up.
private final class PathInfos {
    private let types: [CKRecord.RecordType: any Record.Type]
    private let traversal: Traversal
    private var infos: [CKRecord.RecordType: PathInfo] = [:]

    init(types: [CKRecord.RecordType: any Record.Type], traversal: Traversal) {
        self.types = types
        self.traversal = traversal
    }

    subscript(recordType: CKRecord.RecordType) -> PathInfo {
        if let info = infos[recordType] { return info }
        let references = types[recordType]?.schema.references ?? []
        let info = PathInfo(
            traversed: references.compactMap { reference in
                guard traversal.contains(recordType, reference.property) else { return nil }
                return (PredicateTranslator.Link(reference, of: recordType), reference.target.recordType)
            },
            inverseSources: Set(references.compactMap { reference in
                reference.inverseOf.map { RecordLink.source(type: reference.target.recordType, property: $0) }
            })
        )
        infos[recordType] = info
        return info
    }
}

/// Decodes roots from a loaded graph with the records their traversed references reach. Each
/// record gets only the links it reads, cached per record, so decoding stays proportional to
/// what the references reach.
private final class LoadedReader {
    private let graph: Graph
    private let traversal: Traversal
    private let infos: PathInfos
    private var linksRead: [RecordKey: [RecordLink]] = [:]

    init(graph: Graph, traversal: Traversal, infos: PathInfos) {
        self.graph = graph
        self.traversal = traversal
        self.infos = infos
    }

    /// `root` decoded with its traversed references holding records, `traversal.hops` deep, or
    /// `nil` when the graph doesn't hold it.
    func decode<R: Record>(_ type: R.Type, root: RecordKey) throws -> R? {
        guard let row = graph[root] else { return nil }
        var loaded = RecordGraph()
        for node in reachable(from: root) {
            for link in links(readBy: node) { loaded.add(link) }
            if node != root { loaded[node.recordType, node.name] = graph[node] }
        }
        var record = try R(from: row)
        try loaded.load(&record, depth: traversal.hops)
        return record
    }

    /// The links `node` reads: the ones it owns, and the ones that point at it for its `from:` sides.
    private func links(readBy node: RecordKey) -> [RecordLink] {
        if let links = linksRead[node] { return links }
        let links = graph.links(naming: node.name).filter { link in
            let owns = link.sourceName == node.name && link.sourceType == node.recordType
            let reads = link.targetName == node.name && infos[node.recordType].inverseSources.contains(link.source)
            return owns || reads
        }
        linksRead[node] = links
        return links
    }

    /// `root` and the records it reaches through the traversed references, at most `hops` deep.
    private func reachable(from root: RecordKey) -> [RecordKey] {
        var found: [RecordKey] = [root]
        var seen: Set<RecordKey> = [root]
        var frontier = [root]
        for _ in 0..<traversal.hops {
            var next: [RecordKey] = []
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
                    for record in graph.links(naming: node.name)
                    where record.source == link.source && record.name(in: link.ownName) == node.name {
                        guard let other = record.name(in: link.otherName) else { continue }
                        let key = RecordKey(recordType: target, name: other, zone: graph.zone)
                        if graph[key] != nil, seen.insert(key).inserted {
                            found.append(key)
                            next.append(key)
                        }
                    }
                }
            }
            frontier = next
        }
        return found
    }
}

extension RecordContext {
    /// `fetch` for a predicate that reads through references to records.
    func fetch<R: Record>(
        _ descriptor: RecordDescriptor<R>, matching predicate: Predicate<R>, through traversal: Traversal, filter: SQLFilter?
    ) throws -> [R] {
        // The rows the SQL lets through.
        let (matching, values) = Database.matching(zone: zone, filter: filter)
        let rows = try database.rows("SELECT * FROM \(quoted(R.recordType)) WHERE \(matching)", values)
        var roots: [RecordKey] = []
        var graph = Graph(zone: zone)
        for row in rows {
            guard case .text(let name) = row["_name"] else { continue }
            let key = RecordKey(recordType: R.recordType, name: name, zone: zone)
            graph[key] = RecordRow(row)
            roots.append(key)
        }
        let infos = PathInfos(types: types, traversal: traversal)
        try load(&graph, from: roots, through: traversal, infos: infos, in: zone)

        // Check each root with the records its paths reach loaded.
        let reader = LoadedReader(graph: graph, traversal: traversal, infos: infos)
        var matches: [R] = []
        for root in roots {
            guard let loaded = try reader.decode(R.self, root: root) else { continue }
            if try predicate.evaluate(loaded) { matches.append(loaded) }
        }
        if !descriptor.sortBy.isEmpty { matches.sort(using: descriptor.sortBy) }

        // Return records with references holding IDs. `fetch` then loads their targets.
        return try descriptor.page(of: matches).map { loaded in
            guard let row = graph[RecordKey(recordType: R.recordType, name: loaded.id.uuidString, zone: zone)] else { return loaded }
            var record = try R(from: row)
            try graph.records.load(&record, depth: 0)
            return record
        }
    }

    /// `records` with their references holding the saved records they point at, whose own
    /// references hold IDs. Each of `records` keeps everything else as it is, and follows its
    /// own references, even ones changed since it was saved. The targets are read together, one
    /// query per type, in `zone`, or the context's `zone` without one.
    func loadingChildren<R: Record>(of records: [R], in zone: Zone? = nil) throws -> [R] {
        let zone = zone ?? self.zone
        var targets: [CKRecord.RecordType: Set<String>] = [:]
        for record in records {
            for reference in record.referenceStates where !reference.ids.isEmpty {
                targets[reference.targetType, default: []].formUnion(reference.ids.map(\.uuidString))
            }
        }
        guard !targets.isEmpty else { return records }

        var graph = RecordGraph()
        let (current, zoneValues) = Database.matching(zone: zone, filter: nil)
        for (recordType, names) in targets where types[recordType] != nil {
            for chunk in Array(names).chunked(400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let values = chunk.map(SQLValue.text)
                for row in try database.rows(
                    "SELECT * FROM \(quoted(recordType)) WHERE \(current) AND \"_name\" IN (\(placeholders))",
                    zoneValues + values
                ) {
                    guard case .text(let name) = row["_name"] else { continue }
                    graph[recordType, name] = RecordRow(row)
                }
                // Every link that touches a target, so its own references hold their IDs.
                for row in try database.rows(
                    """
                    SELECT * FROM \(quoted(RecordLink.recordType)) WHERE \(current) \
                    AND ("sourceName" IN (\(placeholders)) OR "targetName" IN (\(placeholders)))
                    """,
                    zoneValues + values + values
                ) {
                    guard case .text(let name) = row["_name"] else { continue }
                    graph.addLink(row, name: name)
                }
            }
        }
        return try records.map { record in
            var record = record
            for reference in record.referenceStates {
                try record.loadReference(reference.property, to: reference.ids, from: graph, depth: 1)
            }
            return record
        }
    }

    /// `record` with its references holding records, as `loadingChildren(of:in:)` loads them.
    func loadingChildren<R: Record>(of record: R, in zone: Zone? = nil) throws -> R {
        try loadingChildren(of: [record], in: zone)[0]
    }

    /// Loads the records `roots` reach through `traversal`, level by level, with every link
    /// that touches each record loaded.
    private func load(
        _ graph: inout Graph, from roots: [RecordKey], through traversal: Traversal, infos: PathInfos, in zone: Zone
    ) throws {
        var frontier = roots
        for level in 0...traversal.hops {
            try loadLinks(for: frontier.map(\.name), into: &graph, in: zone)
            guard level < traversal.hops else { break }

            // The records the traversed references of the frontier point at.
            var next: [CKRecord.RecordType: Set<String>] = [:]
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
                    for record in graph.links(naming: node.name)
                    where record.source == link.source && record.name(in: link.ownName) == node.name {
                        if let other = record.name(in: link.otherName), graph[RecordKey(recordType: target, name: other, zone: zone)] == nil {
                            next[target, default: []].insert(other)
                        }
                    }
                }
            }

            frontier = []
            for (recordType, names) in next {
                guard types[recordType] != nil else { continue }
                for chunk in Array(names).chunked(400) {
                    let (current, zoneValues) = Database.matching(zone: zone, filter: nil)
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    let rows = try database.rows(
                        "SELECT * FROM \(quoted(recordType)) WHERE \(current) AND \"_name\" IN (\(placeholders))",
                        zoneValues + chunk.map(SQLValue.text)
                    )
                    for row in rows {
                        guard case .text(let name) = row["_name"] else { continue }
                        let node = RecordKey(recordType: recordType, name: name, zone: zone)
                        graph[node] = RecordRow(row)
                        frontier.append(node)
                    }
                }
            }
            if frontier.isEmpty { break }
        }
    }

    /// Loads every saved link that touches the records named `names`.
    private func loadLinks(for names: [String], into graph: inout Graph, in zone: Zone) throws {
        let missing = Array(Set(names).subtracting(graph.linksLoaded))
        guard !missing.isEmpty else { return }
        graph.linksLoaded.formUnion(missing)
        let (current, zoneValues) = Database.matching(zone: zone, filter: nil)
        for chunk in missing.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let values = chunk.map(SQLValue.text)
            let rows = try database.rows(
                """
                SELECT * FROM \(quoted(RecordLink.recordType)) WHERE \(current) \
                AND ("sourceName" IN (\(placeholders)) OR "targetName" IN (\(placeholders)))
                """,
                zoneValues + values + values
            )
            for row in rows {
                guard case .text(let name) = row["_name"] else { continue }
                graph.records.addLink(row, name: name)
            }
        }
    }
}

extension Array {
    /// The array in consecutive pieces of at most `size` elements.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

