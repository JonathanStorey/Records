import SwiftSyntax
import SwiftSyntaxMacros

/// `@Encrypted`, a marker that `@Record` reads. It adds nothing itself.
public struct EncryptedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            throw MacroExpansionErrorMessage("@Encrypted can only be applied to a property")
        }
        return []
    }
}
