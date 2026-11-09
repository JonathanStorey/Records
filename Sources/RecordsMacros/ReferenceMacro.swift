import SwiftSyntax
import SwiftSyntaxMacros

/// `@Reference` on a to-one property, e.g. `@Reference var author: Person?`.
///
/// For now it is a marker: it checks the property's shape and adds nothing. `@Record` skips
/// properties marked with it, so they are never written as fields and decode as `nil`.
public struct ReferenceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Reference can only be applied to a property")
        }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@Reference property must be a 'var'")
        }
        guard variable.bindings.count == 1, let binding = variable.bindings.first,
              binding.pattern.is(IdentifierPatternSyntax.self)
        else {
            throw MacroExpansionErrorMessage("@Reference must be applied to a single property")
        }
        guard binding.accessorBlock == nil else {
            throw MacroExpansionErrorMessage("@Reference property must be stored, not computed")
        }
        guard binding.initializer == nil else {
            throw MacroExpansionErrorMessage("@Reference property cannot have an initial value")
        }
        guard let type = binding.typeAnnotation?.type else {
            throw MacroExpansionErrorMessage("@Reference property needs an explicit type annotation")
        }
        if RecordMacro.isArray(type) || RecordMacro.wrappedType(of: type).map(RecordMacro.isArray) == true {
            throw MacroExpansionErrorMessage("@Reference does not support to-many properties yet")
        }
        guard type.is(OptionalTypeSyntax.self) || RecordMacro.wrappedType(of: type) != nil,
              !type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        else {
            throw MacroExpansionErrorMessage("@Reference to one record must be optional, e.g. 'Person?'")
        }
        return []
    }

    /// Whether `variable` carries `@Reference` or `@Records.Reference`.
    static func isReference(_ variable: VariableDeclSyntax) -> Bool {
        variable.attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == "Reference" || name == "Records.Reference"
        }
    }
}
