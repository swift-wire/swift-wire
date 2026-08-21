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
//   • the no-default form yields an optional — the present key gives the value, the absent one nil;
//   • a declared `source:` selector picks *which* provider a site reads from, and two sites with
//     identical arguments reading different providers stay different bindings.
//
// The adapter here is synthetic and has nothing to do with configuration, which is the point: if Wire can
// wire this, it never learned anything domain-specific.

@Provides
func settings() -> SettingsSource {
    SettingsSource(["host": "0.0.0.0", "port": "9090", "level": "debug", "dsn": "postgres://db"])
}

/// A *second* provider of the same type, keyed. Nothing resolves it by type, so a site that wants it has
/// to name it — which is what the selector is for.
enum SettingsKeys {
    static let overrides = BindingKey<SettingsSource>()
}

@Provides(SettingsKeys.overrides)
func overrideSettings() -> SettingsSource {
    SettingsSource(["host": "10.0.0.1", "level": "trace"])
}

/// A plain `String` binding, unannotated. It must keep resolving.
@Provides
func serviceName() -> String { "harness" }

struct Endpoint: Sendable {
    let description: String
}

/// Site 1 — `@Provides func` parameters, including the no-default form (`dsn`, optional).
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

// The two forms of the same thing, which must be equivalent and both expressible. Site 3 is the property
// form; site 2 above is the initialiser-parameter form. A property wrapper "can only be applied to a 'var'",
// so an adapter that were *only* a wrapper would force the property form to give up immutability. The way
// out is to ship two declarations under one name — the wrapper, plus a peer macro — and let Swift resolve
// each use site to whichever applies. The three below must therefore agree.
@Singleton
struct PropertyFormVar: Sendable {
    // Resolves to the property *wrapper* — legal on a `var`.
    @Inject @FromSettings(named: "host", default: "127.0.0.1") var host: String
}

@Singleton
struct PropertyFormLet: Sendable {
    // Resolves to the peer *macro*, because a property wrapper cannot attach to a `let`. Same spelling,
    // same result — which is the whole point: the property form need not give up immutability.
    @Inject @FromSettings(named: "host", default: "127.0.0.1") let host: String
}

@Singleton
struct ParameterForm: Sendable {
    let host: String  // an ordinary `let` — the wrapper is on the parameter, not on this
    @Inject init(@FromSettings(named: "host", default: "127.0.0.1") host: String) { self.host = host }
}

/// The selector, and the case that would break quietly if it left the dedup identity: `host` is read with
/// the *same* arguments from two different providers, so these must be two bindings with two values.
@Singleton
struct SelectedSettings: Sendable {
    let unkeyed: String
    let keyed: String
    let keyedLevel: String

    @Inject init(
        @FromSettings(named: "host", default: "127.0.0.1") unkeyed: String,
        @FromSettings(source: SettingsKeys.overrides, named: "host", default: "127.0.0.1") keyed: String,
        // A key absent from the override source falls back to the default rather than to the other source.
        @FromSettings(source: SettingsKeys.overrides, named: "port", default: 1234) keyedPort: Int,
        @FromSettings(source: SettingsKeys.overrides, named: "level", default: "info") keyedLevel: String
    ) {
        self.unkeyed = unkeyed
        self.keyed = keyed
        self.keyedLevel = keyedLevel
        precondition(keyedPort == 1234, "absent key in the selected source should fall back: \(keyedPort)")
    }
}

/// The selector also works at the property form, where the *macro* half carries it.
@Singleton
struct SelectedProperty: Sendable {
    @Inject @FromSettings(source: SettingsKeys.overrides, named: "host", default: "127.0.0.1") let host: String
}

@Singleton(allowUnused: true)
struct Report: Sendable {
    let text: String
    @Inject init(
        endpoint: Endpoint,
        advertiser: Advertiser,
        settings: LogSettings,
        propertyVar: PropertyFormVar,
        propertyLet: PropertyFormLet,
        parameter: ParameterForm,
        selected: SelectedSettings,
        selectedProperty: SelectedProperty
    ) {
        // Same annotation arguments, different providers — two bindings, two values. One binding here
        // would mean both sites silently read whichever provider won.
        precondition(
            selected.unkeyed == "0.0.0.0" && selected.keyed == "10.0.0.1",
            "selector did not pick the provider: unkeyed=\(selected.unkeyed) keyed=\(selected.keyed)"
        )
        precondition(selected.keyedLevel == "trace", "selected source misread: \(selected.keyedLevel)")
        precondition(
            selectedProperty.host == selected.keyed,
            "property form disagreed with parameter form: \(selectedProperty.host)"
        )
        // All three spellings resolve to the same value, from the same shared binding — the `var` and
        // `let` property forms and the initialiser-parameter form.
        precondition(
            propertyVar.host == parameter.host && propertyLet.host == parameter.host,
            "forms disagree: var=\(propertyVar.host) let=\(propertyLet.host) param=\(parameter.host)"
        )
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
