import SwiftSyntax
import SwiftSyntaxMacros

/// `@Renamed("name")`, a marker that `@Record` reads. It adds nothing itself.
public struct RenamedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Renamed can only be applied to a property")
        }
        return []
    }
}
