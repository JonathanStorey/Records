import SwiftSyntax
import SwiftSyntaxMacros

/// `@Timestamped(.created)` or `@Timestamped(.modified)` on a `Date?` property of a `@Record`.
///
/// A marker that `@Record` reads: it fills the property from the date the server keeps, and never
/// writes it or counts it as a change. It adds nothing itself, so the property stays a plain stored
/// `var` that the memberwise initializer takes with a default of `nil`.
public struct TimestampedMacro: PeerMacro {
    /// Which server date a property reads.
    enum Kind: String {
        case created, modified

        /// The `CKRecord` property that holds the date.
        var recordProperty: String {
            switch self {
            case .created: "creationDate"
            case .modified: "modificationDate"
            }
        }
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Timestamped can only be applied to a property")
        }
        _ = try timestamp(variable, attribute: node)
        return []
    }

    /// The `@Timestamped` attribute on `variable`, if it has one.
    static func attribute(on variable: VariableDeclSyntax) -> AttributeSyntax? {
        for element in variable.attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == "Timestamped" || name == "Records.Timestamped" { return attribute }
        }
        return nil
    }

    /// The name and kind of a valid `@Timestamped` property.
    static func timestamp(
        _ variable: VariableDeclSyntax,
        attribute: AttributeSyntax
    ) throws -> (name: String, kind: Kind) {
        guard let argument = attribute.arguments?.as(LabeledExprListSyntax.self)?.first,
              argument.label == nil,
              let member = argument.expression.as(MemberAccessExprSyntax.self),
              let kind = Kind(rawValue: member.declName.baseName.text)
        else {
            throw MacroExpansionErrorMessage("@Timestamped takes .created or .modified, e.g. @Timestamped(.created)")
        }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else {
            throw MacroExpansionErrorMessage("@Timestamped needs a 'var'")
        }
        guard variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.accessorBlock == nil
        else {
            throw MacroExpansionErrorMessage("@Timestamped needs a single stored property, e.g. 'var createdAt: Date?'")
        }
        let wrapped = binding.typeAnnotation.flatMap { RecordMacro.wrappedType(of: $0.type) }?.trimmedDescription
        guard wrapped == "Date" || wrapped == "Foundation.Date" else {
            throw MacroExpansionErrorMessage("@Timestamped holds 'Date?', which is nil until the record is first saved")
        }
        guard binding.initializer == nil else {
            throw MacroExpansionErrorMessage("The server sets @Timestamped dates, so remove the initial value")
        }
        return (pattern.identifier.text, kind)
    }
}
