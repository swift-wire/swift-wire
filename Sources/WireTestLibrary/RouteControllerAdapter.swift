import Wire

// A minimal stand-in adapter, published by this Wire-aware test library so swift-wire's own IntegrationTests
// can exercise the contributor-proxy and test-variant codegen without a real external adapter (WireMVC et al.
// live in their own repos). `@RouteController` marks a `@Scoped(seed:)` subject as a keyless contributor
// proxy: the build plugin synthesises a standalone bridging proxy (`_WireRouteContributor_<Subject>`)
// carrying a `_wireEnterScope` scope-entry thunk that constructs the subject fresh per request — the same
// machinery an HTTP adapter reaches request scope through.

/// The proxy-contributing marker. A no-op peer macro (`RouteControllerMacro`) so the attribute compiles; the
/// build plugin reads the `WireAdapterAnnotationV1` declaration below to learn what it directs.
@attached(peer)
package macro RouteController() = #externalMacro(module: "WireTestMacrosImpl", type: "RouteControllerMacro")

/// The aggregate marker — a stand-in for WireOpenAPI's `@OpenAPIController`, where the framework demands
/// a *single* conformer for several user types. Every subject bearing it lands on ONE synthesised proxy
/// (`_WireAggregateContributor`), each held or bridged independently. A no-op peer macro, like the others.
@attached(peer)
package macro AggregateController() =
    #externalMacro(module: "WireTestMacrosImpl", type: "RouteControllerMacro")

/// The grouped form: subjects sharing a `spec` land on one proxy, so two values yield two aggregates.
@attached(peer)
package macro AggregateController(spec: String) =
    #externalMacro(module: "WireTestMacrosImpl", type: "RouteControllerMacro")

/// A second aggregate marker with exactly **one** subject — gating the compatibility rule that a
/// one-member aggregate keeps the singular field names (`_wireSubject` / `_wireEnterScope`), so it emits
/// what `.contributesProxy` does and the field-name contract with domain codegen is unchanged.
@attached(peer)
package macro SoloAggregateController() =
    #externalMacro(module: "WireTestMacrosImpl", type: "RouteControllerMacro")

/// A factory-injecting marker (stand-in for WireMVC's `@Middleware(key)`). A no-op peer macro so the
/// attribute compiles; the `.injectsFromGraph` declaration below tells the build plugin to lift the named
/// `@Factory` onto the annotated subject's contributor proxy as a `_wireFactory_<key>` field.
@attached(peer)
package macro RouteMiddleware(_ key: FactoryKey) =
    #externalMacro(module: "WireTestMacrosImpl", type: "RouteMiddlewareMacro")

/// Binds `@RouteController` to a `.liftsPeersToProxy` directive — a standalone, directly-addressable proxy
/// contributing to no multibinding (so the fixture needs no contributor protocol or witness) — and
/// `@RouteMiddleware` to `.injectsFromGraph` (the factory-injection input edge). The build plugin discovers
/// these and synthesises the proxy (carrying any lifted factories) for every `@RouteController` subject.
package enum WireTestRouteAdapter {
    package static let routeController = WireAdapterAnnotationV1(
        annotation: "RouteController",
        capability: .liftsPeersToProxy(proxyTypePrefix: "_WireRouteContributor_", proxyScope: .singleton)
    )

    package static let routeMiddleware = WireAdapterAnnotationV1(
        annotation: "RouteMiddleware",
        capability: .injectsFromGraph
    )

    /// The aggregate directive: collate every `@AggregateController` subject into one proxy, contributed
    /// to `WireTestAggregateKeys.controllers`.
    package static let aggregateController = WireAdapterAnnotationV1(
        annotation: "AggregateController",
        capability: .contributesAggregateProxy(
            to: WireTestAggregateKeys.controllers,
            proxyTypeName: "_WireAggregateContributor",
            proxyScope: .singleton,
            groupedByAttribute: "spec"
        )
    )

    package static let soloAggregateController = WireAdapterAnnotationV1(
        annotation: "SoloAggregateController",
        capability: .contributesAggregateProxy(
            to: WireTestAggregateKeys.soloControllers,
            proxyTypeName: "_WireSoloAggregateContributor",
            proxyScope: .singleton,
            groupedByAttribute: "spec"
        )
    )
}

/// The multibinding the aggregate proxy contributes into — one element, however many subjects it holds.
package enum WireTestAggregateKeys {
    package static let controllers = CollectedKey<any Sendable>()
    package static let soloControllers = CollectedKey<any Sendable>()
}
