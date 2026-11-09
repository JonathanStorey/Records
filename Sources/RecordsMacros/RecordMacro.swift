import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Record` and `@Record("Name")`.
///
/// Adds an extension that conforms the struct to `Records.Record`, with a `recordType` and an
/// `encodeFields(into:)` that writes each stored property except `id` under its own name.
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

        var lines = [
            "extension \(type.trimmedDescription)\(conformance) {",
            "    \(access)static var recordType: CKRecord.RecordType {",
            "        \"\(recordType)\"",
            "    }",
            "    \(access)func encodeFields(into record: CKRecord) {",
        ]
        for property in storedProperties(in: structDecl.memberBlock) where property.key != "id" {
            lines.append("        record[\"\(property.key)\"] = self.\(property.name)")
        }
        lines += ["    }", "}"]

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
            $0.isASCII && ($0.properties.isAlphabetic || ("0" as Unicode.Scalar ... "9").contains($0) || $0 == "_")
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

    /// Instance properties with storage: not static, not lazy, and not computed.
    /// Properties with only `willSet` / `didSet` observers still have storage.
    private static func storedProperties(in members: MemberBlockSyntax) -> [(name: String, key: String)] {
        let skipped: [TokenKind] = [.keyword(.static), .keyword(.class), .keyword(.lazy)]
        var properties: [(name: String, key: String)] = []

        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { skipped.contains($0.name.tokenKind) })
            else { continue }

            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if let accessors = binding.accessorBlock, !hasStorage(accessors) { continue }
                let name = pattern.identifier.text
                properties.append((name: name, key: unescaped(name)))
            }
        }
        return properties
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
