import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Reference` on a property that points at other records: one record, `@Reference var author: Person?`,
/// or many, `@Reference var tags: [Tag]`. Given the record type, it holds only IDs, as in
/// `@Reference(Person.self) var authorID: UUID?` or `@Reference(Tag.self) var tagIDs: [UUID]`.
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
        var accessors: [AccessorDeclSyntax] = [
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
        ]
        // The `from:` side never writes links, so it can only be set when the record is made.
        if !reference.isFrom {
            accessors.append(
                """
                set {
                    \(raw: storage).\(raw: member) = newValue
                }
                """
            )
        }
        return accessors
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
        /// For `@Reference(from: \User.profile)`, the owner's property, such as `profile`.
        /// The owner's type is `target`.
        var ownerProperty: String? = nil
        /// Whether this is the read-only `@Reference(from:)` side.
        var isFrom: Bool { ownerProperty != nil }
        /// For `@Reference(from:deleteSelf:)`, whether the record is deleted with its owner.
        var deleteSelf = false

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

        let name = pattern.identifier.text
        let key = name.filter { $0 != "`" }
        let isID = ["UUID", "Foundation.UUID"].contains(wrapped.trimmedDescription)
        let arguments = node.arguments?.as(LabeledExprListSyntax.self).map(Array.init) ?? []

        // The first argument is `Person.self` or `from: \User.profile`. Only `from:` takes a
        // key path: the owner never names its inverse, because two key paths naming each other's
        // macro-backed properties would make the compiler expand each macro to resolve the other.
        var typeArgument: ExprSyntax?
        var keyPath: (root: String, property: String)?
        if let first = arguments.first {
            let keyPathExpr = first.expression.as(KeyPathExprSyntax.self)
            switch first.label?.text {
            case nil:
                guard keyPathExpr == nil else {
                    throw MacroExpansionErrorMessage(
                        "@Reference takes a record type; name this property in the other side's '@Reference(from:)' instead"
                    )
                }
                typeArgument = first.expression
            case "from":
                guard let keyPathExpr else {
                    throw MacroExpansionErrorMessage("@Reference(from:) takes the owner's property, e.g. '\\User.profile'")
                }
                keyPath = try parse(keyPathExpr, owner: owner)
            default:
                throw MacroExpansionErrorMessage("@Reference takes a record type or 'from:'")
            }
        }
        let isFrom = keyPath != nil
        var deleteSelf = false
        for argument in arguments.dropFirst() {
            guard argument.label?.text == "deleteSelf", isFrom else {
                throw MacroExpansionErrorMessage("Only @Reference(from:) takes 'deleteSelf:'")
            }
            guard let literal = argument.expression.as(BooleanLiteralExprSyntax.self) else {
                throw MacroExpansionErrorMessage("'deleteSelf:' must be 'true' or 'false'")
            }
            deleteSelf = literal.literal.tokenKind == .keyword(.true)
        }

        // Anything can point at a record, so a to-many inverse has no natural size limit. It
        // holds IDs, so loading the record never loads every owner.
        if isFrom, isToMany, !isID {
            throw MacroExpansionErrorMessage(
                "A to-many @Reference(from:) holds IDs, e.g. 'var \(key.hasSuffix("s") ? String(key.dropLast()) : key)IDs: [UUID]'"
            )
        }
        // Deleting one of many owners can't mean deleting this record.
        if deleteSelf, isToMany {
            throw MacroExpansionErrorMessage("'deleteSelf:' needs a to-one @Reference(from:) property")
        }
        // `UUID?` and `[UUID]` hold only IDs, so the target type has to be named.
        if isID, !isFrom, typeArgument == nil {
            throw MacroExpansionErrorMessage(
                "@Reference on a UUID needs the record type it points at, e.g. '@Reference(Person.self)'"
            )
        }
        if !isID, typeArgument != nil {
            throw MacroExpansionErrorMessage(
                "@Reference only takes a record type on a UUID property; '\(wrapped.trimmedDescription)' already names it"
            )
        }

        // `Self` cannot appear in a stored property's type, so name the struct instead.
        func resolved(_ type: String) -> String { type == "Self" ? owner ?? type : type }

        var target = resolved(wrapped.trimmedDescription)
        if let typeArgument {
            guard let member = typeArgument.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.tokenKind == .keyword(.self),
                  let base = member.base
            else {
                throw MacroExpansionErrorMessage("@Reference takes a record type, e.g. 'Person.self'")
            }
            target = resolved(base.trimmedDescription)
        }
        if let keyPath {
            if !isID, keyPath.root != target {
                throw MacroExpansionErrorMessage(
                    "The key path's type '\(keyPath.root)' does not match the property's type '\(target)'"
                )
            }
            if keyPath.root == owner, keyPath.property == key {
                throw MacroExpansionErrorMessage("@Reference to itself is not supported yet")
            }
            target = keyPath.root
        }

        return Reference(
            name: name, key: key, target: target, isID: isID, isToMany: isToMany,
            ownerProperty: keyPath?.property, deleteSelf: deleteSelf
        )
    }

    /// The root type and property of a key path such as `\Profile.user`.
    private static func parse(_ keyPath: KeyPathExprSyntax, owner: String?) throws -> (root: String, property: String) {
        guard let root = keyPath.root?.trimmedDescription,
              keyPath.components.count == 1,
              let component = keyPath.components.first?.component.as(KeyPathPropertyComponentSyntax.self)
        else {
            throw MacroExpansionErrorMessage("@Reference(from:) takes a key path to one property, e.g. '\\User.profile'")
        }
        let property = component.declName.baseName.text.filter { $0 != "`" }
        return (root == "Self" ? owner ?? root : root, property)
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
