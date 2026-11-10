import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Location` on a `Coordinate?` property of a `@Record`, stored as an encrypted `CLLocation`.
///
/// Turns the property into a computed one backed by a `Records.LocationField` named with a leading
/// underscore, which keeps the `CLLocation` itself. `$name` reads and sets that `CLLocation`. An
/// init accessor keeps the property in the memberwise initializer.
///
/// Only the peer role reports problems, so each one is reported once.
public struct LocationMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let (_, storage) = try? location(variable)
        else { return [] }
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = Records.LocationField(initialValue)
            }
            """,
            """
            get {
                \(raw: storage).coordinate
            }
            """,
            """
            set {
                \(raw: storage).coordinate = newValue
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
            throw MacroExpansionErrorMessage("@Location can only be applied to a property")
        }
        let (key, storage) = try location(variable)
        return [
            "var \(raw: storage): Records.LocationField",
            """
            \(raw: accessLevel(of: variable))var $\(raw: key): Records.LocationField.Stored? {
                get {
                    \(raw: storage).location
                }
                set {
                    \(raw: storage).location = newValue
                }
            }
            """,
        ]
    }

    /// Whether `variable` carries `@Location` or `@Records.Location`.
    static func isLocation(_ variable: VariableDeclSyntax) -> Bool {
        variable.attributes.contains {
            let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            return name == "Location" || name == "Records.Location"
        }
    }

    /// The key and storage name of a valid `@Location` property.
    private static func location(_ variable: VariableDeclSyntax) throws -> (key: String, storage: String) {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@Location needs a 'var'")
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.accessorBlock == nil
        else {
            throw MacroExpansionErrorMessage("@Location needs a single stored property, e.g. 'var venue: Coordinate?'")
        }
        let wrapped = binding.typeAnnotation.flatMap { RecordMacro.wrappedType(of: $0.type) }?.trimmedDescription
        guard wrapped == "Coordinate" || wrapped == "Records.Coordinate" else {
            throw MacroExpansionErrorMessage("@Location holds 'Coordinate?', e.g. 'var venue: Coordinate?'")
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
