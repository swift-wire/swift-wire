import SwiftSyntax

extension BindingDiscovery {
    /// Record a `@TestScopable` marker on a type declaration into the module-global set — keyed by the type's
    /// simple name, matching how the cascade + seedless reconstruction name their reconstruction candidates.
    /// Called from each nominal-type visit (struct/class/actor).
    func recordTestScopable(name: TokenSyntax, attributes: AttributeListSyntax) {
        if hasAttribute(attributes, named: "TestScopable") {
            testScopableTypes.insert(name.text)
        }
    }
}
