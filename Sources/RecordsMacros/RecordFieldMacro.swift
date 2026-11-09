import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@RecordField`, which `@Record` adds to each stored `var` except `id` and `@Reference`
/// properties.
///
/// Turns the property into a computed one backed by a `Records.Field` named with a leading
/// underscore, which notes when the value is set. An init accessor keeps the property in the
/// memberwise initializer, with its initial value as the default.
public struct RecordFieldMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let (storage, _) = field(declaration) else { return [] }
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = Records.Field(initialValue)
            }
            """,
            """
            get {
                \(raw: storage).value
            }
            """,
            """
            set {
                \(raw: storage).value = newValue
            }
            """,
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let (storage, type) = field(declaration) else { return [] }
        return ["var \(raw: storage): Records.Field<\(raw: type)>"]
    }

    /// The storage name and value type of a single stored `var` with a type annotation.
    private static func field(_ declaration: some DeclSyntaxProtocol) -> (storage: String, type: String)? {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              variable.bindingSpecifier.tokenKind == .keyword(.var),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              binding.accessorBlock == nil,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let type = binding.typeAnnotation?.type
        else { return nil }
        let name = pattern.identifier.text.filter { $0 != "`" }
        // `Int!` isn't a type a generic can take, so store it as `Int?`.
        let valueType = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self)
            .map { "\($0.wrappedType.trimmedDescription)?" } ?? type.trimmedDescription
        return ("_\(name)", valueType)
    }
}
