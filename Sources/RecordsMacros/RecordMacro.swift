import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` and `@Record("Name")`.
///
/// Adds an extension that conforms the struct to `Records.Record`, with a `recordType`, an
/// `init(record:)` that reads each stored property back, and an `encodeFields(into:)` that writes
/// each stored property except `id` under its own name. A struct with `@Reference` properties
/// also gets `referenceStates`, `loadReference(_:to:from:links:depth:)`, and `markReferencesSaved()`,
/// one with `@Reference(from:)` gets `inverse(of:in:)`, and one with
/// `@Reference(from:deleteSelf: true)` gets `deleteSelfReferences`.
public struct RecordMacro: ExtensionMacro {
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

        let properties = try storedProperties(in: structDecl.memberBlock)
        guard properties.contains(where: { $0.key == "id" }) else {
            throw MacroExpansionErrorMessage("@Record requires a stored 'id: UUID' property")
        }
        let fields = properties.filter { $0.key != "id" }
        let references = references(in: structDecl.memberBlock, owner: structDecl.name.text)

        var lines = [
            "extension \(type.trimmedDescription)\(conformance) {",
            "    \(access)static var recordType: CKRecord.RecordType {",
            "        \"\(recordType)\"",
            "    }",
            "    \(access)init(record: CKRecord) throws {",
            "        self.id = try CKRecordDecoder.decodeID(from: record)",
        ]
        for field in fields {
            let read: String
            if let wrapped = field.wrappedType {
                read = "decodeIfPresent((\(wrapped)).self, forKey: \"\(field.key)\", from: record)"
            } else if field.isArray {
                // CloudKit does not keep empty lists, so a missing array field means empty.
                read = "decodeIfPresent((\(field.type)).self, forKey: \"\(field.key)\", from: record) ?? []"
            } else {
                read = "decode((\(field.type)).self, forKey: \"\(field.key)\", from: record)"
            }
            lines.append("        self.\(field.name) = try CKRecordDecoder.\(read)")
        }
        // Links hold references, so a decoded record starts with none. `loadReference` fills them.
        for reference in references {
            let empty = reference.isToMany ? "Records.ToMany(ids: [])" : "Records.ToOne(id: nil)"
            lines.append("        self.\(reference.storage) = \(empty)")
        }
        lines += [
            "    }",
            "    \(access)func encodeFields(into record: CKRecord) {",
        ]
        for field in fields {
            lines.append("        record[\"\(field.key)\"] = self.\(field.name)")
        }
        lines.append("    }")
        let deleteSelf = references.filter(\.deleteSelf).map { "\"\($0.key)\"" }
        if !deleteSelf.isEmpty {
            lines += [
                "    \(access)static var deleteSelfReferences: Set<String> {",
                "        [\(deleteSelf.joined(separator: ", "))]",
                "    }",
            ]
        }
        let inverses = references.filter(\.isFrom)
        if !inverses.isEmpty {
            // The owner's encoder asks for its inverse here. The key path checks that the owner's
            // property exists and points back at this type.
            lines += [
                "    \(access)static func inverse(of property: String, in owner: CKRecord.RecordType) -> Records.Inverse? {",
                "        switch (owner, property) {",
            ]
            var named = Set<String>()
            for reference in inverses {
                let ownerProperty = reference.ownerProperty ?? ""
                // The owner's links name one inverse, so two can't share an owner's property.
                guard named.insert("\(reference.target).\(ownerProperty)").inserted else {
                    throw MacroExpansionErrorMessage(
                        "Only one @Reference(from:) can name '\(reference.target).\(ownerProperty)'"
                    )
                }
                let label = reference.isToMany ? "many: " : ""
                let deleteSelf = reference.deleteSelf ? ", deleteSelf: true" : ""
                lines += [
                    "        case (\(reference.target).recordType, \"\(ownerProperty)\"):",
                    "            return Records.Inverse(\(label)\\\(reference.target).\(ownerProperty), to: Self.self, property: \"\(reference.key)\"\(deleteSelf))",
                ]
            }
            lines += [
                "        default:",
                "            return nil",
                "        }",
                "    }",
            ]
        }
        if !references.isEmpty {
            // `@Reference(from:)` properties never write links, so the encoder doesn't see them.
            lines.append("    \(access)var referenceStates: [Records.ReferenceState] {")
            lines.append("        [")
            for reference in references where !reference.isFrom {
                lines.append("            self.\(reference.storage).state(property: \"\(reference.key)\", owner: Self.recordType),")
            }
            lines += [
                "        ]",
                "    }",
                "    \(access)mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {",
                "        switch property {",
            ]
            for reference in references {
                // The ID form never holds the records, so it ignores them.
                lines += [
                    "        case \"\(reference.key)\":",
                    "            try self.\(reference.storage).load(targets, \(reference.isID ? "from: [], links: [], depth: 0" : "from: records, links: links, depth: depth"))",
                ]
            }
            lines += [
                "        default:",
                "            break",
                "        }",
                "    }",
                "    \(access)mutating func markReferencesSaved() {",
            ]
            for reference in references {
                lines.append("        self.\(reference.storage).markSaved()")
            }
            lines.append("    }")
        }
        lines.append("}")

        let decl = DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
        guard let extensionDecl = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
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
        /// The CloudKit field key: the name without backticks.
        let key: String
        /// The declared type, as written.
        let type: String
        /// The wrapped type when the declared type is optional, such as `Int` for `Int?`.
        let wrappedType: String?
        /// Whether the declared type is `[T]` or `Array<T>`.
        let isArray: Bool
    }

    /// The valid `@Reference` properties. `@Reference` itself reports invalid ones.
    private static func references(in members: MemberBlockSyntax, owner: String) -> [ReferenceMacro.Reference] {
        members.members.compactMap { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  let attribute = ReferenceMacro.attribute(on: variable)
            else { return nil }
            return try? ReferenceMacro.reference(variable, attribute: attribute, owner: owner)
        }
    }

    /// Instance properties with storage that `init(record:)` can assign: not static, not lazy,
    /// not computed, and not a `let` with an initial value. Properties with only `willSet` /
    /// `didSet` observers still have storage. Each one needs an explicit type, because the
    /// generated initializer decodes by type.
    private static func storedProperties(in members: MemberBlockSyntax) throws -> [StoredProperty] {
        let skipped: [TokenKind] = [.keyword(.static), .keyword(.class), .keyword(.lazy)]
        var properties: [StoredProperty] = []

        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { skipped.contains($0.name.tokenKind) }),
                  !ReferenceMacro.isReference(variable) // Links hold references, not fields.
            else { continue }
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
                            "@Record cannot decode 'id' because it is a 'let' with an initial value; use 'var id = UUID()' or 'let id: UUID'"
                        )
                    }
                    continue // A constant: nothing to read or write.
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
                    type: type.trimmedDescription,
                    wrappedType: wrapped?.trimmedDescription,
                    isArray: isArray(type)
                ))
            }
            properties += found.reversed()
        }
        return properties
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
