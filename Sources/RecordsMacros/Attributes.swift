import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

extension VariableDeclSyntax {
    /// The `@name` or `@Records.name` attribute on the property, if any.
    func attribute(_ name: String) -> AttributeSyntax? {
        attributes.lazy.compactMap { $0.as(AttributeSyntax.self) }.first {
            let written = $0.attributeName.trimmedDescription
            return written == name || written == "Records.\(name)"
        }
    }

    /// Whether the property carries `@name` or `@Records.name`.
    func has(_ name: String) -> Bool {
        attribute(name) != nil
    }
}

/// A marker attribute, such as `@Encrypted` or `@Renamed`, that `@Record` reads. It adds nothing
/// itself.
public struct MarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            let name = node.attributeName.trimmedDescription.replacingOccurrences(of: "Records.", with: "")
            throw MacroExpansionErrorMessage("@\(name) can only be applied to a property")
        }
        return []
    }
}

/// A property macro, such as `@Asset` or `@Location`, that turns an optional property into a
/// computed one backed by a `Records` field named with a leading underscore. `$name` reads and
/// sets what the field stores. An init accessor keeps the property in the memberwise initializer.
///
/// Only the peer role reports problems, so each one is reported once.
struct BackedProperty {
    /// The attribute, such as `Asset`.
    let attribute: String
    /// The backing type, such as `AssetField`.
    let field: String
    /// The field's member that holds the property's value, such as `data`.
    let value: String
    /// The type and field member of `$name`, such as `URL?` and `fileURL`.
    let projected: (type: String, member: String)
    /// The names the property's wrapped type may be written as.
    let wrapped: Set<String>
    /// An example declaration, such as `var cover: Data?`.
    let example: String

    func accessors(of declaration: some DeclSyntaxProtocol) -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let (_, storage) = try? names(of: variable)
        else { return [] }
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = Records.\(raw: field)(initialValue)
            }
            """,
            """
            get {
                \(raw: storage).\(raw: value)
            }
            """,
            """
            set {
                \(raw: storage).\(raw: value) = newValue
            }
            """,
        ]
    }

    func peers(of declaration: some DeclSyntaxProtocol) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@\(attribute) can only be applied to a property")
        }
        let (key, storage) = try names(of: variable)
        return [
            "var \(raw: storage): Records.\(raw: field)",
            """
            \(raw: RecordMacro.accessLevel(of: variable))var $\(raw: key): \(raw: projected.type) {
                get {
                    \(raw: storage).\(raw: projected.member)
                }
                set {
                    \(raw: storage).\(raw: projected.member) = newValue
                }
            }
            """,
        ]
    }

    /// The key and storage name of a valid property.
    private func names(of variable: VariableDeclSyntax) throws -> (key: String, storage: String) {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@\(attribute) needs a 'var'")
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.accessorBlock == nil
        else {
            throw MacroExpansionErrorMessage("@\(attribute) needs a single stored property, e.g. '\(example)'")
        }
        let type = binding.typeAnnotation.flatMap { RecordMacro.wrappedType(of: $0.type) }?.trimmedDescription
        guard let type, wrapped.contains(type) else {
            let shown = example.split(separator: ": ").last.map(String.init) ?? ""
            throw MacroExpansionErrorMessage("@\(attribute) holds '\(shown)', e.g. '\(example)'")
        }
        if attribute == "Asset", variable.has("Encrypted") {
            throw MacroExpansionErrorMessage("CloudKit can't encrypt an asset, so a property can't be both @Asset and @Encrypted")
        }
        let key = pattern.identifier.text.filter { $0 != "`" }
        return (key, "_\(key)")
    }
}
