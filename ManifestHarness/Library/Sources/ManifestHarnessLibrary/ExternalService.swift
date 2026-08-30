/// Stands in for a binding a real Wire-aware library would publish. The gate
/// asserts the *manifest describing it* crosses the package boundary through
/// the plugin-output channel, not that the type does (the type crosses by
/// ordinary linking, which was never in question).
public struct ExternalService: Sendable {
    public let name: String
    public init() { self.name = "external" }
}
