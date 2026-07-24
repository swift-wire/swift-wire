import Wire

// A minimal stand-in adapter, published by this Wire-aware test library so swift-wire's own IntegrationTests
// can exercise the contributor-proxy codegen (M5.4 / M6a) without a real external adapter (WireMVC et al.
// live in their own repos). `@RouteController` marks a `@Scoped(seed:)` subject as a keyless contributor
// proxy: the build plugin synthesises a standalone bridging proxy (`_WireRouteContributor_<Subject>`)
// carrying a `_wireEnterScope` scope-entry thunk that constructs the subject fresh per request — the same
// machinery an HTTP adapter reaches request scope through.

/// The proxy-contributing marker. A no-op peer macro (`RouteControllerMacro`) so the attribute compiles; the
/// build plugin reads the `WireAdapterAnnotationV1` declaration below to learn what it directs.
@attached(peer)
package macro RouteController() = #externalMacro(module: "WireTestMacrosImpl", type: "RouteControllerMacro")

/// Binds `@RouteController` to a `.liftsPeersToProxy` directive — a standalone, directly-addressable proxy
/// contributing to no multibinding (so the fixture needs no contributor protocol or witness). The build
/// plugin discovers this declaration and synthesises the proxy for every `@RouteController` subject.
package enum WireTestRouteAdapter {
    package static let routeController = WireAdapterAnnotationV1(
        annotation: "RouteController",
        capability: .liftsPeersToProxy(proxyTypePrefix: "_WireRouteContributor_", proxyScope: .singleton)
    )
}
