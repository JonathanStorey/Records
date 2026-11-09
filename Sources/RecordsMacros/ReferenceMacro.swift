import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Reference` on a to-one property, either the record itself, `@Reference var author: Person?`,
/// or only its ID, `@Reference(to: Person.self) var authorID: UUID?`.
///
/// Turns the property into a computed one backed by a `Records.ToOne` named with a leading
/// underscore. The storage keeps the current target ID, the ID last loaded or saved, and, for the
/// record form, the loaded record. An init accessor keeps the property in the memberwise
/// initializer.
///
/// Only the peer role reports problems, so each one is reported once. The accessor role adds
/// nothing to a property it cannot handle.
public struct ReferenceMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let reference = try? reference(variable, attribute: node, owner: owner(in: context))
        else { return [] }

        let storage = reference.storage
        let initial = reference.isID ? "Records.ToOne(id: initialValue)" : "Records.ToOne(initialValue)"
        let member = reference.isID ? "id" : "value"
        return [
            """
            @storageRestrictions(initializes: \(raw: storage))
            init(initialValue) {
                \(raw: storage) = \(raw: initial)
            }
            """,
            """
            get {
                \(raw: storage).\(raw: member)
            }
            """,
            """
            set {
                \(raw: storage).\(raw: member) = newValue
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
            throw MacroExpansionErrorMessage("@Reference can only be applied to a property")
        }
        let reference = try reference(variable, attribute: node, owner: owner(in: context))
        return ["var \(raw: reference.storage): Records.ToOne<\(raw: reference.target)>"]
    }

    /// A valid to-one `@Reference` property.
    struct Reference {
        /// The identifier as written, including any backticks.
        let name: String
        /// The name without backticks. Also the property name in the link's signature.
        let key: String
        /// The target record type as written, such as `Person`.
        let target: String
        /// Whether the property holds only the target's ID.
        let isID: Bool

        /// The generated storage property, such as `_author`.
        var storage: String { "_" + key }
    }

    /// Checks the property's shape and reads its target type.
    ///
    /// `owner` is the enclosing struct's name, used to resolve `Self`.
    static func reference(
        _ variable: VariableDeclSyntax,
        attribute node: AttributeSyntax,
        owner: String?
    ) throws -> Reference {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@Reference property must be a 'var'")
        }
        guard variable.bindings.count == 1, let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
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

        // `UUID?` holds only the ID, so the target type has to be named: `@Reference(to: Person.self)`.
        let argument = node.arguments?.as(LabeledExprListSyntax.self)?.first
        let isID = ["UUID", "Foundation.UUID"].contains(wrapped.trimmedDescription)
        if isID, argument == nil {
            throw MacroExpansionErrorMessage(
                "@Reference on a UUID needs the record type it points at, e.g. '@Reference(to: Person.self)'"
            )
        }
        if !isID, argument != nil {
            throw MacroExpansionErrorMessage(
                "@Reference only takes a record type on a UUID property; '\(wrapped.trimmedDescription)' already names it"
            )
        }

        var target = wrapped.trimmedDescription
        if let argument {
            guard let member = argument.expression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.tokenKind == .keyword(.self),
                  let base = member.base
            else {
                throw MacroExpansionErrorMessage("@Reference(to:) takes a record type, e.g. 'Person.self'")
            }
            target = base.trimmedDescription
        }
        // `Self` cannot appear in a stored property's type, so name the struct instead.
        if target == "Self", let owner {
            target = owner
        }

        let name = pattern.identifier.text
        return Reference(name: name, key: name.filter { $0 != "`" }, target: target, isID: isID)
    }

    /// The `@Reference` or `@Records.Reference` attribute on `variable`, if any.
    static func attribute(on variable: VariableDeclSyntax) -> AttributeSyntax? {
        for element in variable.attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == "Reference" || name == "Records.Reference" { return attribute }
        }
        return nil
    }

    /// Whether `variable` carries `@Reference` or `@Records.Reference`.
    static func isReference(_ variable: VariableDeclSyntax) -> Bool {
        attribute(on: variable) != nil
    }

    private static func owner(in context: some MacroExpansionContext) -> String? {
        context.lexicalContext.first?.as(StructDeclSyntax.self)?.name.text
    }
}
