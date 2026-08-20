import Configuration
import Wire
import WireConfiguration

// The `.rewritesInjection` gate: an annotated injection site stops resolving by its own type and instead
// resolves to a producer Wire synthesises, which asks the annotation's own property wrapper for the value.
//
// What it proves, end to end through the real plugin:
//   • all three annotated sites work — `@Provides func` parameter, `@Inject init` parameter, `@Inject` property;
//   • the value reaches the consumer, read from the `ConfigReader` the graph supplies;
//   • two sites with the *same* annotation arguments and type share one binding (dedup by key), and
//     different arguments stay distinct;
//   • an ordinary unannotated binding of the same type (`String`) is untouched and still resolves — the
//     rewrite is keyed, so it cannot capture a plain dependency;
//   • the required form (no `default:`) reads a present value.
//
// swift-wire knows none of what any of that *means*: it copies the annotation's arguments verbatim into
// `Configuration<T>(…).wireValue(from:)`.

/// The reader every rewrite resolves against — an ordinary graph binding, here a `@Provides`. A real app
/// more often passes one in as a `@GraphInputs` value built before the graph.
@Provides
func configReader() -> ConfigReader {
    ConfigReader(
        provider: InMemoryProvider(values: [
            AbsoluteConfigKey(["server", "host"]): "0.0.0.0",
            AbsoluteConfigKey(["server", "port"]): 9090,
            AbsoluteConfigKey(["log", "level"]): "debug",
            AbsoluteConfigKey(["required", "dsn"]): "postgres://db",
        ])
    )
}

/// A plain `String` binding, unannotated. It must keep resolving: rewrites are keyed, so they never
/// capture an ordinary dependency of the same type.
@Provides
func serviceName() -> String { "harness" }

/// Site 1 — `@Provides func` parameters. `host` is defaulted-and-absent-in-config's sense (present here),
/// `port` reads an Int, and `dsn` uses the *required* form (no `default:`).
struct Endpoint: Sendable {
    let description: String
}

@Provides
func endpoint(
    @Configuration(forKey: "server.host", default: "127.0.0.1") host: String,
    @Configuration(forKey: "server.port", default: 8080) port: Int,
    @Configuration(forKey: "required.dsn") dsn: String,
    name: String  // ordinary, unannotated — resolves to `serviceName()`
) -> Endpoint {
    Endpoint(description: "\(name)@\(host):\(port) -> \(dsn)")
}

/// Site 2 — `@Inject init` parameter. Its `server.host` annotation is *identical* to `endpoint`'s, so both
/// must share one synthesised binding rather than reading twice.
@Singleton
struct Advertiser: Sendable {
    let host: String
    @Inject init(@Configuration(forKey: "server.host", default: "127.0.0.1") host: String) {
        self.host = host
    }
}

/// Site 3 — `@Inject` property.
@Singleton
struct LogSettings: Sendable {
    @Inject @Configuration(forKey: "log.level", default: "info") var level: String
}

@Singleton(allowUnused: true)
struct Report: Sendable {
    let text: String
    @Inject init(endpoint: Endpoint, advertiser: Advertiser, settings: LogSettings) {
        text = "\(endpoint.description) | advertised=\(advertiser.host) | level=\(settings.level)"
    }
}

let graph = try await Wire.bootstrap()

let expected = "harness@0.0.0.0:9090 -> postgres://db | advertised=0.0.0.0 | level=debug"
precondition(
    graph.report.text == expected,
    "configuration did not reach the graph:\n  expected \(expected)\n  actual   \(graph.report.text)"
)

print("configuration harness OK — \(graph.report.text)")
