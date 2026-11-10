import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Timestamped(.created)` or `@Timestamped(.modified)` on a `Date?` property of a `@Record`.
///
/// Turns the property into a read-only one backed by a `Records.ServerDate` named with a leading
/// underscore, which `@Record` fills from the date the server keeps. The storage is a `let` with a
/// default value, so the memberwise initializer leaves it out. Assigning the property doesn't
/// compile.
///
/// Only the peer role reports problems, so each one is reported once.
public struct TimestampedMacro: AccessorMacro, PeerMacro {
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
        let timestamp = try timestamp(variable, attribute: node)
        return ["let \(raw: timestamp.storage) = Records.ServerDate()"]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let timestamp = try? timestamp(variable, attribute: node)
        else { return [] }
        return [
            """
            get {
                \(raw: timestamp.storage).date
            }
            """,
        ]
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

    /// The storage name and kind of a valid `@Timestamped` property.
    static func timestamp(
        _ variable: VariableDeclSyntax,
        attribute: AttributeSyntax
    ) throws -> (storage: String, kind: Kind) {
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
        return ("_" + pattern.identifier.text.filter { $0 != "`" }, kind)
    }
}
