import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Experiment only: does a key path argument to another type's macro-backed property cycle?
public struct ProbeMacro: AccessorMacro, PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let name = declaration.as(VariableDeclSyntax.self)?.bindings.first?.pattern.trimmedDescription else { return [] }
        let getOnly = node.attributeName.trimmedDescription == "ProbeGet"
        var result: [AccessorDeclSyntax] = [
            """
            @storageRestrictions(initializes: _\(raw: name))
            init(initialValue) {
                _\(raw: name) = initialValue
            }
            """,
            "get { _\(raw: name) }",
        ]
        if !getOnly { result.append("set { _\(raw: name) = newValue }") }
        return result
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let binding = declaration.as(VariableDeclSyntax.self)?.bindings.first,
              let type = binding.typeAnnotation?.type else { return [] }
        return ["var _\(raw: binding.pattern.trimmedDescription): \(type)"]
    }
}
