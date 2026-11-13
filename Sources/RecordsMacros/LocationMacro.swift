import SwiftSyntax
import SwiftSyntaxMacros

/// `@Location` on a `Coordinate?` property of a `@Record`, stored as an encrypted `CLLocation`.
///
/// The property is backed by a `Records.LocationField`, which keeps the `CLLocation` itself.
/// `$name` reads and sets that `CLLocation`.
public struct LocationMacro: AccessorMacro, PeerMacro {
    static let property = BackedProperty(
        attribute: "Location", field: "LocationField", value: "coordinate",
        projected: ("Records.LocationField.Stored?", "location"),
        wrapped: ["Coordinate", "Records.Coordinate"], example: "var venue: Coordinate?"
    )

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        property.accessors(of: declaration)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try property.peers(of: declaration)
    }
}
