import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Asset` on a `Data?` property of a `@Record`, stored as a `CKAsset` on its own link.
///
/// Turns the property into a computed one backed by a `Records.AssetField` named with a leading
/// underscore, which keeps the file and reads it only when the property is read. `$name` gives the
/// file's URL, and setting it copies a file in without reading it. An init accessor keeps the property in the memberwise initializer.
///
/// Only the peer role reports problems, so each one is reported once.
public struct AssetMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let (_, storage) = try? asset(variable)
        else { return [] }
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = Records.AssetField(initialValue)
            }
            """,
            """
            get {
                \(raw: storage).data
            }
            """,
            """
            set {
                \(raw: storage).data = newValue
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Asset can only be applied to a property")
        }
        let (key, storage) = try asset(variable)
        return [
            "var \(raw: storage): Records.AssetField",
            """
            \(raw: accessLevel(of: variable))var $\(raw: key): URL? {
                get {
                    \(raw: storage).fileURL
                }
                set {
                    \(raw: storage).fileURL = newValue
                }
            }
            """,
        ]
    }

    /// Whether `variable` carries `@Asset` or `@Records.Asset`.
    static func isAsset(_ variable: VariableDeclSyntax) -> Bool {
        variable.attributes.contains {
            let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            return name == "Asset" || name == "Records.Asset"
        }
    }

    /// The key and storage name of a valid `@Asset` property.
    private static func asset(_ variable: VariableDeclSyntax) throws -> (key: String, storage: String) {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@Asset needs a 'var'")
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.accessorBlock == nil
        else {
            throw MacroExpansionErrorMessage("@Asset needs a single stored property, e.g. 'var cover: Data?'")
        }
        let isData = binding.typeAnnotation.flatMap { RecordMacro.wrappedType(of: $0.type) }?.trimmedDescription == "Data"
        guard isData else {
            throw MacroExpansionErrorMessage("@Asset holds 'Data?', e.g. 'var cover: Data?'")
        }
        if variable.attributes.contains(where: {
            let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            return name == "Encrypted" || name == "Records.Encrypted"
        }) {
            throw MacroExpansionErrorMessage("CloudKit can't encrypt an asset, so a property can't be both @Asset and @Encrypted")
        }
        let key = pattern.identifier.text.filter { $0 != "`" }
        return (key, "_\(key)")
    }

    /// `public `, `package `, `fileprivate `, or `private ` when the property has it.
    private static func accessLevel(of variable: VariableDeclSyntax) -> String {
        let levels: [Keyword] = [.public, .package, .internal, .fileprivate, .private]
        for modifier in variable.modifiers where modifier.detail == nil {
            if case .keyword(let keyword) = modifier.name.tokenKind, levels.contains(keyword) {
                return keyword == .internal ? "" : "\(modifier.name.text) "
            }
        }
        return ""
    }
}
