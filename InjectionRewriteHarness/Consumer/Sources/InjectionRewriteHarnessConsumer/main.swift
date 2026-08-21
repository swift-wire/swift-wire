import Wire
import WireHarnessSettings

// The `.rewritesInjection` gate: an annotated injection site stops resolving by its own type and instead
// resolves to a producer Wire synthesises, which asks the annotation's own property wrapper for the value.
//
// What it proves, end to end through the real plugin:
//   • all three annotated sites work — `@Provides func` parameter, `@Inject init` parameter, `@Inject` property;
//   • two sites with the *same* annotation arguments and type share one binding, and different ones stay distinct;
//   • an ordinary unannotated binding of the same type is untouched — the rewrite is keyed, so it cannot
//     capture a plain dependency;
//   • the no-default form yields an optional — the present key gives the value, the absent one nil.
//
// The adapter here is synthetic and has nothing to do with configuration, which is the point: if Wire can
// wire this, it never learned anything domain-specific.

@Provides
func settings() -> SettingsSource {
    SettingsSource(["host": "0.0.0.0", "port": "9090", "level": "debug", "dsn": "postgres://db"])
}

/// A plain `String` binding, unannotated. It must keep resolving.
@Provides
func serviceName() -> String { "harness" }

struct Endpoint: Sendable {
    let description: String
}

/// Site 1 — `@Provides func` parameters, including the no-default form (`dsn`).
@Provides
func endpoint(
    @FromSettings(named: "host", default: "127.0.0.1") host: String,
    @FromSettings(named: "port", default: 8080) port: Int,
    @FromSettings(named: "dsn") dsn: String?,  // no default, present → the value
    @FromSettings(named: "absent") missing: String?,  // no default, absent → nil
    name: String  // ordinary, unannotated — resolves to `serviceName()`
) -> Endpoint {
    Endpoint(description: "\(name)@\(host):\(port) -> \(dsn ?? "<none>")/\(missing ?? "<none>")")
}

/// Site 2 — `@Inject init` parameter. Its annotation is *identical* to `endpoint`'s `host`, so both must
/// share one synthesised binding rather than reading twice.
@Singleton
struct Advertiser: Sendable {
    let host: String
    @Inject init(@FromSettings(named: "host", default: "127.0.0.1") host: String) {
        self.host = host
    }
}

/// Site 3 — `@Inject` property.
@Singleton
struct LogSettings: Sendable {
    @Inject @FromSettings(named: "level", default: "info") var level: String
}

@Singleton(allowUnused: true)
struct Report: Sendable {
    let text: String
    @Inject init(endpoint: Endpoint, advertiser: Advertiser, settings: LogSettings) {
        text = "\(endpoint.description) | advertised=\(advertiser.host) | level=\(settings.level)"
    }
}

let graph = try await Wire.bootstrap()

let expected = "harness@0.0.0.0:9090 -> postgres://db/<none> | advertised=0.0.0.0 | level=debug"
precondition(
    graph.report.text == expected,
    "rewritten sites did not resolve:\n  expected \(expected)\n  actual   \(graph.report.text)"
)

print("injection-rewrite harness OK — \(graph.report.text)")
