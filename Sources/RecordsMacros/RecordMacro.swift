import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` and `@Record("Name")`.
///
/// Adds an extension that conforms the struct to `Records.Record`, with a `recordType`, a
/// `schema`, an `init(from row:)` that reads each stored property from its database row, and an
/// `encodeFields(into:)` that writes each one except `id`. The schema turns a row into a
/// `CKRecord` and back, so no record type writes its own. A struct with `@Reference` properties
/// also gets `referenceStates` and `loadReference(_:to:from:depth:)`. The schema describes
/// every reference, including the `@Reference(from:)` sides, so the encoder finds each inverse
/// there.
///
/// An `@Asset` field is stored on its own link, so a struct with one gets `assetStates` and
/// `loadAsset(_:id:file:)`.
///
/// A struct that declares no `id` gets `var id = Name.ID()`, so each new value has its own.
public struct RecordMacro: ExtensionMacro, MemberMacro {
    /// Modifiers that mean a property isn't stored per record.
    private static var skipped: [TokenKind] { [.keyword(.static), .keyword(.class), .keyword(.lazy)] }

    /// `var id`, when the struct declares none. The extension role reports any problems.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self), !declaresID(structDecl.memberBlock) else { return [] }
        let generics = structDecl.genericParameterClause.map { clause in
            "<" + clause.parameters.map(\.name.text).joined(separator: ", ") + ">"
        } ?? ""
        let type = "Records.RecordID<\(structDecl.name.text)\(generics)>"
        return ["\(raw: accessModifier(for: structDecl.modifiers))var id: \(raw: type) = Records.RecordID()"]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Record can only be applied to a struct")
        }

        let recordType = try recordType(from: node, for: structDecl)
        let access = accessModifier(for: structDecl.modifiers)
        let conformance = protocols.isEmpty ? "" : ": Records.Record"

        var properties = try storedProperties(in: structDecl.memberBlock, owner: structDecl.name.text)
        if !declaresID(structDecl.memberBlock) {
            // The `id` the member role adds.
            properties.insert(StoredProperty(
                name: "id", key: "id", fieldKey: "id", type: "Records.RecordID<Self>", wrappedType: nil,
                isArray: false, isEncrypted: false, isAsset: false, isLocation: false
            ), at: 0)
        }
        let fields = properties.filter { $0.key != "id" }
        let references = references(in: structDecl.memberBlock, owner: structDecl.name.text)

        var lines = [
            "extension \(type.trimmedDescription)\(conformance) {",
            "    \(access)static var recordType: CKRecord.RecordType {",
            "        \"\(recordType)\"",
            "    }",
        ] + schemaLines(
            recordType: recordType, fields: fields, references: references, access: access,
            isGeneric: structDecl.genericParameterClause != nil
        )
            + keyPathLines(typeName: type.trimmedDescription, fields: fields, references: references, access: access)
        lines += rowLines(fields: fields, references: references, timestamps: timestamps(in: structDecl.memberBlock), access: access)
        let assets = fields.filter(\.isAsset)
        if !assets.isEmpty {
            // Each asset is stored on a link named by its field key, so `@Renamed` keeps it.
            lines.append("    \(access)var assetStates: [Records.AssetState] {")
            lines.append("        [")
            for field in assets {
                lines.append("            self._\(field.key).state(property: \"\(field.fieldKey)\"),")
            }
            lines += [
                "        ]",
                "    }",
                "    \(access)mutating func loadAsset(_ property: String, id: UUID?, file: URL?) {",
                "        switch property {",
            ]
            for field in assets {
                lines += [
                    "        case \"\(field.fieldKey)\":",
                    "            self._\(field.key) = Records.AssetField(id: id, file: file)",
                ]
            }
            lines += [
                "        default:",
                "            break",
                "        }",
                "    }",
            ]
        }
        // The owner's links name one inverse, so two can't share an owner's property.
        var named = Set<String>()
        for reference in references where reference.isFrom {
            let ownerProperty = reference.ownerProperty ?? ""
            guard named.insert("\(reference.target).\(ownerProperty)").inserted else {
                throw MacroExpansionErrorMessage(
                    "Only one @Reference(from:) can name '\(reference.target).\(ownerProperty)'"
                )
            }
        }
        if !references.isEmpty {
            // `@Reference(from:)` properties never write links, so the encoder doesn't see them.
            let owning = references.filter { !$0.isFrom }
            lines.append("    \(access)var referenceStates: [Records.ReferenceState] {")
            if owning.isEmpty {
                lines.append("        Records.ReferenceState.all(of: Self.self, targets: [:])")
            } else {
                lines.append("        Records.ReferenceState.all(of: Self.self, targets: [")
                for reference in owning {
                    lines.append("            \"\(reference.key)\": (self.\(reference.storage).ids.map(\\.rawValue), self.\(reference.storage).loadedRecords),")
                }
                lines.append("        ])")
            }
            lines += [
                "    }",
                "    \(access)mutating func loadReference(_ property: String, to targets: [UUID], from graph: Records.RecordGraph, depth: Int) throws {",
                "        switch property {",
            ]
            for reference in references {
                // A `from:` side holds IDs, so it reads no records.
                lines += [
                    "        case \"\(reference.key)\":",
                    "            try self.\(reference.storage).load(targets, from: graph, depth: \(reference.isFrom ? "0" : "depth"))",
                ]
            }
            lines += [
                "        default:",
                "            break",
                "        }",
                "    }",
            ]
        }
        lines += codableLines(for: structDecl, properties: properties, references: references, access: access)
        lines.append("}")

        let decl = DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
        guard let extensionDecl = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    /// `init(from row:)` and `encodeFields(into row:)`: every stored property read from and
    /// written to its column, and the dates read from theirs.
    private static func rowLines(
        fields: [StoredProperty], references: [ReferenceMacro.Reference],
        timestamps: [(storage: String, kind: TimestampedMacro.Kind)], access: String
    ) -> [String] {
        var lines = [
            "    \(access)init(from row: Records.RecordRow) throws(Records.CKRecordDecodingError) {",
            "        self.id = Records.RecordID(rawValue: try row.id)",
        ]
        for field in fields {
            if field.isAsset {
                lines.append("        self._\(field.key) = Records.AssetField(id: nil, file: nil)")
                continue
            }
            if field.isLocation {
                lines.append("        self._\(field.key) = try Records.LocationField(saved: Records.LocationField.coding.decodeIfPresent(\"\(field.fieldKey)\", from: row))")
                continue
            }
            let read: String
            if let wrapped = field.wrappedType {
                read = "Records.FieldCoding((\(wrapped)).self).decodeIfPresent(\"\(field.fieldKey)\", from: row)"
            } else if field.isArray {
                read = "Records.FieldCoding((\(field.type)).self).decodeIfPresent(\"\(field.fieldKey)\", from: row) ?? []"
            } else {
                read = "Records.FieldCoding((\(field.type)).self).decode(\"\(field.fieldKey)\", from: row)"
            }
            lines.append("        self.\(field.name) = try \(read)")
        }
        for reference in references {
            let empty = reference.isToMany
                ? "Records.ToMany(ids: [])"
                : "Records.ToOne(id: nil)"
            lines.append("        self.\(reference.storage) = \(empty)")
        }
        for timestamp in timestamps {
            lines.append("        self.\(timestamp.storage).load(row.\(timestamp.kind.rowProperty))")
        }
        lines += [
            "    }",
            "    \(access)func encodeFields(into row: inout Records.RecordRow) {",
        ]
        for field in fields where !field.isAsset {
            let coding = field.isLocation ? "Records.LocationField.coding" : "Records.FieldCoding((\(field.wrappedType ?? field.type)).self)"
            let value = field.isLocation ? "self._\(field.key).location" : "self.\(field.name)"
            lines.append("        \(coding).encode(\(value), into: &row, forKey: \"\(field.fieldKey)\")")
        }
        lines.append("    }")
        return lines
    }

    /// The static `schema` the container builds its tables from. It is built once, except on a
    /// generic type, which can't have a static stored property.
    private static func schemaLines(
        recordType: String,
        fields: [StoredProperty],
        references: [ReferenceMacro.Reference],
        access: String,
        isGeneric: Bool
    ) -> [String] {
        var lines = [
            "        Records.RecordSchema(",
            "            recordType: \"\(recordType)\",",
        ]
        let stored = fields.filter { !$0.isAsset }
        if stored.isEmpty {
            lines.append("            fields: [],")
        } else {
            lines.append("            fields: [")
            for field in stored {
                let kind = field.isLocation ? "Records.LocationField.coding.kind" : "Records.FieldCoding((\(field.wrappedType ?? field.type)).self).kind"
                lines.append("                Records.FieldSchema(name: \"\(field.key)\", key: \"\(field.fieldKey)\", isOptional: \(field.wrappedType != nil), isEncrypted: \(field.isEncrypted), kind: \(kind)),")
            }
            lines.append("            ],")
        }
        if references.isEmpty {
            lines.append("            references: []")
        } else {
            lines.append("            references: [")
            for reference in references {
                var arguments = "property: \"\(reference.key)\", target: \(reference.target).self, isToMany: \(reference.isToMany)"
                if let owner = reference.ownerProperty {
                    arguments += ", inverseOf: \"\(owner)\", deleteSelf: \(reference.deleteSelf)"
                }
                lines.append("                Records.ReferenceSchema(\(arguments)),")
            }
            lines.append("            ]")
        }
        lines.append("        )")
        guard isGeneric else {
            // Stored once: the same lines, one level out.
            return ["    \(access)static let schema = Records.RecordSchema("]
                + lines.dropFirst().map { String($0.dropFirst(4)) }
        }
        return ["    \(access)static var schema: Records.RecordSchema {"] + lines + ["    }"]
    }

    /// `keyPaths`: what each property is saved as, by its key path, so a predicate on it can
    /// become SQL. `id` is the record's name, a stored property its column, and a `@Reference`
    /// its property name.
    private static func keyPathLines(
        typeName: String, fields: [StoredProperty], references: [ReferenceMacro.Reference], access: String
    ) -> [String] {
        let entries = ["\\\(typeName).id: \"_name\""]
            + fields.filter { !$0.isAsset && !$0.isLocation }.map { "\\\(typeName).\($0.key): \"\($0.fieldKey)\"" }
            + references.map { "\\\(typeName).\($0.key): \"\($0.key)\"" }
        return [
            "    \(access)static var keyPaths: [PartialKeyPath<Self>: String] {",
            "        [\(entries.joined(separator: ", "))]",
            "    }",
        ]
    }

    /// `encode(to:)` and `init(from:)` for a struct that declares `Codable`, `Encodable`, or
    /// `Decodable`, since the storage behind the wrappers can't be synthesized.
    ///
    /// Each property is keyed by its Swift name. A reference encodes its target IDs, an asset its
    /// ID, and a location its coordinate. Timestamps and constants are left out. A struct that
    /// writes either method itself keeps its own.
    private static func codableLines(
        for decl: StructDeclSyntax,
        properties: [StoredProperty],
        references: [ReferenceMacro.Reference],
        access: String
    ) -> [String] {
        let inherited = Set((decl.inheritanceClause?.inheritedTypes ?? []).map { inherited -> String in
            let name = inherited.type.trimmedDescription
            return name.hasPrefix("Swift.") ? String(name.dropFirst(6)) : name
        })
        let methods = decl.memberBlock.members.map(\.decl)
        let writesEncode = methods.contains {
            guard let function = $0.as(FunctionDeclSyntax.self) else { return false }
            return function.name.text == "encode"
                && function.signature.parameterClause.parameters.map(\.firstName.text) == ["to"]
        }
        let writesInit = methods.contains {
            $0.as(InitializerDeclSyntax.self)?.signature.parameterClause.parameters.map(\.firstName.text) == ["from"]
        }
        let encodes = !inherited.isDisjoint(with: ["Codable", "Encodable"]) && !writesEncode
        let decodes = !inherited.isDisjoint(with: ["Codable", "Decodable"]) && !writesInit
        guard encodes || decodes else { return [] }

        let keys = properties.map(\.key) + references.map(\.key)
        var lines = [
            "    private enum _RecordCodingKeys: String, CodingKey {",
        ] + keys.map { "        case `\($0)`" } + ["    }"]

        if encodes {
            lines += [
                "    \(access)func encode(to encoder: any Encoder) throws {",
                "        var container = encoder.container(keyedBy: _RecordCodingKeys.self)",
            ]
            for property in properties {
                let key = ".`\(property.key)`"
                if property.isAsset {
                    lines.append("        try container.encodeIfPresent(self._\(property.key).id, forKey: \(key))")
                } else if property.isLocation {
                    lines.append("        try container.encodeIfPresent(self._\(property.key).coordinate, forKey: \(key))")
                } else if property.wrappedType != nil {
                    lines.append("        try container.encodeIfPresent(self.\(property.name), forKey: \(key))")
                } else {
                    lines.append("        try container.encode(self.\(property.name), forKey: \(key))")
                }
            }
            for reference in references {
                let key = ".`\(reference.key)`"
                if reference.isToMany {
                    lines.append("        try container.encode(self.\(reference.storage).ids, forKey: \(key))")
                } else {
                    lines.append("        try container.encodeIfPresent(self.\(reference.storage).id, forKey: \(key))")
                }
            }
            lines.append("    }")
        }

        if decodes {
            lines += [
                "    \(access)init(from decoder: any Decoder) throws {",
                "        let container = try decoder.container(keyedBy: _RecordCodingKeys.self)",
            ]
            for property in properties {
                let key = ".`\(property.key)`"
                if property.isAsset {
                    // The data stays in its file. On a device that has it, the ID finds it again.
                    lines.append("        self._\(property.key) = Records.AssetField(id: try container.decodeIfPresent(UUID.self, forKey: \(key)), file: nil)")
                } else if property.isLocation {
                    lines.append("        self._\(property.key) = Records.LocationField(try container.decodeIfPresent(Records.Coordinate.self, forKey: \(key)))")
                } else if let wrapped = property.wrappedType {
                    lines.append("        self.\(property.name) = try container.decodeIfPresent((\(wrapped)).self, forKey: \(key))")
                } else {
                    lines.append("        self.\(property.name) = try container.decode((\(property.type)).self, forKey: \(key))")
                }
            }
            // References come back holding IDs only, as after a load with depth 0.
            for reference in references {
                let key = ".`\(reference.key)`"
                if reference.isToMany {
                    lines.append("        self.\(reference.storage) = Records.ToMany(ids: try container.decodeIfPresent([Records.RecordID<\(reference.target)>].self, forKey: \(key)) ?? [])")
                } else {
                    lines.append("        self.\(reference.storage) = Records.ToOne(id: try container.decodeIfPresent(Records.RecordID<\(reference.target)>.self, forKey: \(key)))")
                }
            }
            lines.append("    }")
        }
        return lines
    }

    /// The name passed to `@Record("Name")`, or the struct's name.
    private static func recordType(from node: AttributeSyntax, for decl: StructDeclSyntax) throws -> String {
        if let argument = node.arguments?.as(LabeledExprListSyntax.self)?.first {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  let name = literal.representedLiteralValue
            else {
                throw MacroExpansionErrorMessage("@Record name must be a string literal")
            }
            guard isValidRecordType(name) else {
                throw MacroExpansionErrorMessage(
                    "'\(name)' is not a valid record type; use letters, digits, and underscores, starting with a letter"
                )
            }
            return name
        }

        if decl.genericParameterClause != nil {
            throw MacroExpansionErrorMessage(
                "Generic types need an explicit record type, e.g. @Record(\"\(unescaped(decl.name.text))\")"
            )
        }
        return unescaped(decl.name.text)
    }

    /// CloudKit record types start with a letter and contain only letters, digits, and underscores.
    private static func isValidRecordType(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.properties.isAlphabetic, first.isASCII else {
            return false
        }
        return name.count <= 255 && name.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value) || $0 == "_")
        }
    }

    /// `public` or `package` when the struct has it, so the conformance is as visible as the type.
    private static func accessModifier(for modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }

    /// A stored property that `@Record` reads and writes.
    private struct StoredProperty {
        /// The identifier as written, including any backticks.
        let name: String
        /// The name without backticks, which names the storage.
        let key: String
        /// The CloudKit field key: the `@Renamed` name, or `key`.
        let fieldKey: String
        /// The declared type, as written.
        let type: String
        /// The wrapped type when the declared type is optional, such as `Int` for `Int?`.
        let wrappedType: String?
        /// Whether the declared type is `[T]` or `Array<T>`.
        let isArray: Bool
        /// Whether it is marked `@Encrypted`, so it is stored in `encryptedValues`.
        let isEncrypted: Bool

        /// Whether it is marked `@Asset`, so it is stored on its own link.
        let isAsset: Bool

        /// Whether it is marked `@Location`, so it is stored as an encrypted archive of its `CLLocation`.
        let isLocation: Bool
    }

    /// Whether the struct declares a property named `id`.
    private static func declaresID(_ members: MemberBlockSyntax) -> Bool {
        members.members.contains { member in
            member.decl.as(VariableDeclSyntax.self)?.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self).map { unescaped($0.identifier.text) } == "id"
            } ?? false
        }
    }

    /// The valid `@Reference` properties. `@Reference` itself reports invalid ones.
    private static func references(in members: MemberBlockSyntax, owner: String) -> [ReferenceMacro.Reference] {
        members.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  let attribute = variable.attribute("Reference")
            else { return nil }
            return try? ReferenceMacro.reference(variable, attribute: attribute, owner: owner)
        }
    }

    /// Instance properties with storage that `init(from:)` can assign: not static, not lazy,
    /// not computed, and not a `let` with an initial value. Properties with only `willSet` /
    /// `didSet` observers still have storage. Each one needs an explicit type, because the
    /// generated initializer decodes by type.
    private static func storedProperties(in members: MemberBlockSyntax, owner: String) throws -> [StoredProperty] {
        var properties: [StoredProperty] = []

        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { skipped.contains($0.name.tokenKind) })
            else { continue }
            let isAsset = variable.has("Asset")
            let isLocation = variable.has("Location")
            // A location says where someone is, so it is always encrypted.
            let isEncrypted = variable.has("Encrypted") || isLocation
            let renamed = try renamedKey(variable)
            if variable.has("Timestamped") {
                // The server sets the date, so there is no field to encrypt, rename, or write.
                if isEncrypted {
                    throw MacroExpansionErrorMessage("The server sets @Timestamped dates, so they can't be @Encrypted")
                }
                if renamed != nil {
                    throw MacroExpansionErrorMessage("The server sets @Timestamped dates, so they have no field to rename")
                }
                continue
            }
            if variable.has("Reference") {
                // Links hold references, not fields.
                if isEncrypted {
                    throw MacroExpansionErrorMessage("@Encrypted applies to fields, not to a @Reference")
                }
                if renamed != nil {
                    throw MacroExpansionErrorMessage("@Renamed applies to fields, not to a @Reference")
                }
                continue
            }
            if renamed != nil, variable.bindings.count > 1 {
                throw MacroExpansionErrorMessage("@Renamed applies to one field; declare it on its own line")
            }
            let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)

            // In `var a, b: String`, only `b` spells the type, so walk backwards and carry it.
            var carriedType: TypeSyntax?
            var found: [StoredProperty] = []
            for binding in variable.bindings.reversed() {
                if let annotation = binding.typeAnnotation {
                    carriedType = annotation.type
                } else if binding.initializer != nil {
                    carriedType = nil
                }

                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if let accessors = binding.accessorBlock, !hasStorage(accessors) { continue }
                let name = pattern.identifier.text
                let key = unescaped(name)

                if isLet, binding.initializer != nil {
                    if key == "id" {
                        throw MacroExpansionErrorMessage(
                            "@Record cannot decode 'id' because it is a 'let' with an initial value; leave 'id' out and @Record adds 'var id = \(owner).ID()'"
                        )
                    }
                    continue // A constant: nothing to read or write.
                }
                if key == "id", isEncrypted {
                    throw MacroExpansionErrorMessage("'id' is the record name, which CloudKit can't encrypt")
                }
                if key == "id", renamed != nil {
                    throw MacroExpansionErrorMessage("'id' is the record name, so it has no field to rename")
                }
                guard let type = binding.typeAnnotation?.type ?? carriedType else {
                    throw MacroExpansionErrorMessage("@Record property '\(key)' needs an explicit type annotation")
                }
                let wrapped = wrappedType(of: type)
                if let wrapped, isArray(wrapped) {
                    // CloudKit stores an empty list and a missing field the same way.
                    throw MacroExpansionErrorMessage("Record does not support an optional array")
                }
                found.append(StoredProperty(
                    name: name,
                    key: key,
                    fieldKey: renamed ?? key,
                    type: type.trimmedDescription,
                    wrappedType: wrapped?.trimmedDescription,
                    isArray: isArray(type),
                    isEncrypted: isEncrypted,
                    isAsset: isAsset,
                    isLocation: isLocation
                ))
            }
            properties += found.reversed()
        }
        // Two properties can't share a CloudKit field.
        var keys = Set<String>()
        for property in properties where property.key != "id" {
            guard keys.insert(property.fieldKey).inserted else {
                throw MacroExpansionErrorMessage("Two properties are stored in the field '\(property.fieldKey)'")
            }
        }
        return properties
    }

    /// The field name in `@Renamed("name")` on `variable`, if any.
    private static func renamedKey(_ variable: VariableDeclSyntax) throws -> String? {
        guard let attribute = variable.attribute("Renamed") else { return nil }
        guard let argument = attribute.arguments?.as(LabeledExprListSyntax.self)?.first,
              let literal = argument.expression.as(StringLiteralExprSyntax.self),
              let key = literal.representedLiteralValue
        else {
            throw MacroExpansionErrorMessage("@Renamed takes the field's original name as a string literal, e.g. @Renamed(\"released\")")
        }
        guard isValidRecordType(key) else {
            throw MacroExpansionErrorMessage("'\(key)' is not a valid field name; use letters, digits, and underscores, starting with a letter")
        }
        return key
    }

    /// The valid `@Timestamped` properties. `@Timestamped` itself reports invalid ones.
    private static func timestamps(in members: MemberBlockSyntax) -> [(storage: String, kind: TimestampedMacro.Kind)] {
        members.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  let attribute = variable.attribute("Timestamped"),
                  let timestamp = try? TimestampedMacro.timestamp(variable, attribute: attribute)
            else { return nil }
            return (timestamp.storage, timestamp.kind)
        }
    }

    /// `public `, `package `, `fileprivate `, or `private ` when the property has it, for the
    /// peers a property macro adds beside it.
    static func accessLevel(of variable: VariableDeclSyntax) -> String {
        let levels: [Keyword] = [.public, .package, .internal, .fileprivate, .private]
        for modifier in variable.modifiers where modifier.detail == nil {
            if case .keyword(let keyword) = modifier.name.tokenKind, levels.contains(keyword) {
                return keyword == .internal ? "" : "\(modifier.name.text) "
            }
        }
        return ""
    }

    /// `Int` for `Int?`, `Int!`, or `Optional<Int>`; `nil` for any other type.
    static func wrappedType(of type: TypeSyntax) -> TypeSyntax? {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return optional.wrappedType
        }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return unwrapped.wrappedType
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
           identifier.name.text == "Optional",
           let arguments = identifier.genericArgumentClause?.arguments,
           arguments.count == 1,
           let argument = arguments.first {
            return argument.argument.as(TypeSyntax.self)
        }
        return nil
    }

    static func isArray(_ type: TypeSyntax) -> Bool {
        if type.is(ArrayTypeSyntax.self) { return true }
        if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text == "Array" }
        return false
    }

    private static func hasStorage(_ accessors: AccessorBlockSyntax) -> Bool {
        switch accessors.accessors {
        case .getter:
            return false
        case .accessors(let list):
            let observers: [TokenKind] = [.keyword(.willSet), .keyword(.didSet)]
            return list.allSatisfy { observers.contains($0.accessorSpecifier.tokenKind) }
        }
    }

    /// Drops the backticks from an escaped identifier such as `` `default` ``.
    private static func unescaped(_ name: String) -> String {
        String(name.filter { $0 != "`" })
    }
}
