// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// Applied to every Swift target in this package.
//
// **`NonisolatedNonsendingByDefault`** is here for *agreement*, not for anything swift-wire needs on its
// own. Every adapter downstream — wire-mvc, wire-open-api — already enables it, and until now swift-wire
// did not, so a bare `@Sendable () async -> …` meant `@concurrent` in a `Wire` declaration and
// `nonisolated(nonsending)` in the generated file an adapter compiles. A protocol requirement of that
// shape is then unsatisfiable by a type that prints identically to it, which is exactly how it was found:
// `WireScopeEntry` shipped with a teardown requirement, swift-wire's own suite passed (a package agrees
// with itself), and WireOpenAPI's fixtures refused the emitted conformance.
//
// Enabling it costs nothing measurable here — the package builds warning-free and every test passes — and
// it is the default in Swift 7 regardless. It is not, on its own, sufficient: a protocol carrying no
// function type at all is immune whether or not a given consumer agrees, which is why `WireScopeEntry`
// requires only the subject.
let wireSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "swift-wire",
    platforms: [
        // macOS 15 is required for the `Synchronization` module's
        // `Mutex` type, used by `Lazy<T>`'s internal box. Linux is
        // unaffected (Synchronization ships with Swift 6.0+ on
        // Linux); this constraint only narrows the development-on-
        // macOS audience to macOS 15+. Servers run Linux, where
        // the deployment target is Swift 6.0+ regardless.
        .macOS(.v15)
    ],
    products: [
        .library(name: "Wire", targets: ["Wire"]),
        // The test-graph vocabulary — `TestingKey` and `@BindType`. Split from `Wire` so that declaring a
        // variant is a *dependency* a target has to take, not something every Wire consumer can reach by
        // default: a production target that never links this cannot compile a `TestingKey()` at all, which
        // is an earlier and plainer failure than WireGen's `--testing-variants` refusal.
        //
        // `@TestScopable` deliberately stays in `Wire`. It marks a production type as safe to rebuild per
        // request under test, so it is written in production sources — moving it here would make every
        // module carrying one depend on the testing target, which is the opposite of the point.
        .library(name: "WireTesting", targets: ["WireTesting"]),
        .plugin(name: "WireBuildPlugin", targets: ["WireBuildPlugin"]),
        // The codegen executable, exposed so an adapter package's build plugin can invoke it via
        // `context.tool(named: "WireGen")` — an adapter that owns route (or other domain) codegen runs
        // WireGen for the graph + structural half, then its own domain tool. See the WireMVC codegen
        // notes: the build plugin moves to the adapter.
        .executable(name: "WireGen", targets: ["WireGen"]),
    ],
    dependencies: [
        // Floor at 603.0.0 (Swift 6.3) so Wire can use SE-0491 module
        // selectors — both round-tripping module-qualified types through
        // codegen and recognising `@Wire::`-qualified macro attributes —
        // which the 601/602 (6.1/6.2) parsers don't have.
        .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"604.0.0")
    ],
    targets: [
        .target(
            name: "Wire",
            dependencies: ["WireMacrosImpl"],
            swiftSettings: wireSettings
        ),
        // The test-graph vocabulary. Depends on `Wire` for `BindingKey` (the keyed `@BindType` overload names
        // it) and on the same macro plugin — `@BindType` is a marker macro, so which module *declares* it is
        // free, and declaring it here is what makes the dependency visible in a consumer's manifest.
        .target(
            name: "WireTesting",
            dependencies: ["Wire", "WireMacrosImpl"],
            swiftSettings: wireSettings
        ),
        .macro(
            name: "WireMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: wireSettings
        ),
        // Test-only macro plugin: hosts `@RouteController` (a stand-in adapter marker) so swift-wire's
        // IntegrationTests can induce a contributor proxy. Only `WireTestLibrary` depends on it, so it is
        // never built into a consumer's macro plugin the way `WireMacrosImpl` is.
        .macro(
            name: "WireTestMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: wireSettings
        ),
        .target(
            name: "WireGenCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: wireSettings
        ),
        .executableTarget(
            name: "WireGen",
            dependencies: ["WireGenCore"],
            swiftSettings: wireSettings
        ),
        .plugin(
            name: "WireBuildPlugin",
            capability: .buildTool(),
            dependencies: ["WireGen"]
        ),
        .testTarget(
            name: "WireTests",
            dependencies: ["Wire", "WireTesting"],
            swiftSettings: wireSettings
        ),
        .testTarget(
            name: "WireMacrosImplTests",
            dependencies: [
                "WireMacrosImpl",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: wireSettings
        ),
        .testTarget(
            name: "WireGenCoreTests",
            dependencies: ["WireGenCore"],
            swiftSettings: wireSettings
        ),
        // A same-package, Wire-aware library the IntegrationTests target
        // composes via cross-target source reading (iteration 7c). It opts
        // in by depending on the `Wire` product (this replaced the
        // hand-declared marker file) and exposes a public
        // `@Singleton`; it has no plugin of its own — the consumer's plugin
        // re-parses its sources.
        .target(
            name: "WireTestLibrary",
            dependencies: ["Wire", "WireTestMacrosImpl"],
            swiftSettings: wireSettings
        ),
        .testTarget(
            name: "IntegrationTests",
            // `WireTesting` for the `TestingKey`/`@BindType` fixtures — a test target takes it explicitly,
            // which is the whole point of the split.
            dependencies: ["Wire", "WireTesting", "WireTestLibrary"],
            swiftSettings: wireSettings,
            plugins: [.plugin(name: "WireBuildPlugin")]
        ),
    ]
)
