import SwiftSyntax
import SwiftSyntaxMacros

/// `@Reference` on a to-one property, either the record itself, `@Reference var author: Person?`,
/// or only its ID, `@Reference(to: Person.self) var authorID: UUID?`.
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
        guard let wrapped = RecordMacro.wrappedType(of: type),
              !type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        else {
            throw MacroExpansionErrorMessage("@Reference to one record must be optional")
        }

        // A struct cannot store an optional of itself. Until references get boxed storage,
        // point at the same type by ID instead.
        if let owner = context.lexicalContext.first?.as(StructDeclSyntax.self)?.name.text,
           [owner, "Self"].contains(wrapped.trimmedDescription) {
            let property = binding.pattern.trimmedDescription
            throw MacroExpansionErrorMessage(
                "@Reference to its own type is not supported yet; use '@Reference(to: \(owner).self) var \(property)ID: UUID?'"
            )
        }

        // `UUID?` holds only the ID, so the target type has to be named: `@Reference(to: Person.self)`.
        let hasTargetType = node.arguments?.as(LabeledExprListSyntax.self)?.isEmpty == false
        let isID = ["UUID", "Foundation.UUID"].contains(wrapped.trimmedDescription)
        if isID, !hasTargetType {
            throw MacroExpansionErrorMessage(
                "@Reference on a UUID needs the record type it points at, e.g. '@Reference(to: Person.self)'"
            )
        }
        if !isID, hasTargetType {
            throw MacroExpansionErrorMessage(
                "@Reference only takes a record type on a UUID property; '\(wrapped.trimmedDescription)' already names it"
            )
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
