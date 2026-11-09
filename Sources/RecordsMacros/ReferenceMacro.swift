import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Reference` on a property that points at other records: one record, `@Reference var author: Person?`,
/// or many, `@Reference var tags: [Tag]`. With `(to:)` it holds only IDs, as in
/// `@Reference(to: Person.self) var authorID: UUID?` or `@Reference(to: Tag.self) var tagIDs: [UUID]`.
///
/// Turns the property into a computed one backed by a `Records.ToOne` or `Records.ToMany` named
/// with a leading underscore. The storage keeps the current targets, the targets last loaded or
/// saved, and, for the record form, the loaded records. An init accessor keeps the property in the memberwise
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
        let initial = switch (reference.isToMany, reference.isID) {
        case (false, true): "Records.ToOne(id: initialValue)"
        case (false, false): "Records.ToOne(initialValue)"
        case (true, true): "Records.ToMany(ids: initialValue)"
        case (true, false): "Records.ToMany(initialValue)"
        }
        let member = switch (reference.isToMany, reference.isID) {
        case (false, true): "id"
        case (false, false): "value"
        case (true, true): "ids"
        case (true, false): "values"
        }
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
        let storageType = reference.isToMany ? "ToMany" : "ToOne"
        return ["var \(raw: reference.storage): Records.\(raw: storageType)<\(raw: reference.target)>"]
    }

    /// A valid to-one `@Reference` property.
    struct Reference {
        /// The identifier as written, including any backticks.
        let name: String
        /// The name without backticks. Also the property name in the link's signature.
        let key: String
        /// The target record type as written, such as `Person`.
        let target: String
        /// Whether the property holds only the target IDs.
        let isID: Bool
        /// Whether the property holds many targets, `[Target]` or `[UUID]`.
        let isToMany: Bool

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
        if RecordMacro.wrappedType(of: type).map(RecordMacro.isArray) == true {
            throw MacroExpansionErrorMessage("@Reference to many records must be a non-optional array")
        }
        // `[Tag]` points at many records, `Person?` at one. `wrapped` is the record or ID type.
        let isToMany = RecordMacro.isArray(type)
        let wrapped: TypeSyntax
        if isToMany {
            guard let element = elementType(of: type) else {
                throw MacroExpansionErrorMessage("@Reference to many records must be a non-optional array")
            }
            wrapped = element
        } else {
            guard let optional = RecordMacro.wrappedType(of: type),
                  !type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
            else {
                throw MacroExpansionErrorMessage("@Reference to one record must be optional")
            }
            wrapped = optional
        }

        // `UUID?` and `[UUID]` hold only IDs, so the target type has to be named: `@Reference(to: Person.self)`.
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
        return Reference(name: name, key: name.filter { $0 != "`" }, target: target, isID: isID, isToMany: isToMany)
    }

    /// `Tag` for `[Tag]` or `Array<Tag>`.
    private static func elementType(of type: TypeSyntax) -> TypeSyntax? {
        if let array = type.as(ArrayTypeSyntax.self) { return array.element }
        if let identifier = type.as(IdentifierTypeSyntax.self),
           let arguments = identifier.genericArgumentClause?.arguments, arguments.count == 1 {
            return arguments.first?.argument.as(TypeSyntax.self)
        }
        return nil
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
