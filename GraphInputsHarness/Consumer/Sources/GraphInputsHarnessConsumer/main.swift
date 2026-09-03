import Wire

// The graph-inputs gate: values the caller constructs and hands to `Wire.bootstrap(inputs:)`, the
// root-graph counterpart of a seeded scope's seed.
//
// What it proves, end to end through the real plugin:
//   • an unkeyed input injects by type like any other binding;
//   • two same-typed inputs coexist by keying them (`@Provides(key)` — the producer-side spelling), and
//     reach a consumer through `@Bind(key)`;
//   • an input is a leaf ordinary bindings consume, which is the whole point: it carries a value the
//     graph cannot construct for itself;
//   • a computed property is not an input (no value to pass in), so it neither becomes a binding nor
//     collides with the keyed `String`s.
//
// Its own package because `@GraphInputs` changes `Wire.bootstrap`'s signature for the whole module — see
// Package.swift.

struct RuntimeConfiguration: Sendable {
    let endpoint: String
}

enum InputKeys {
    static let region = BindingKey<String>()
    static let stage = BindingKey<String>()
}

@GraphInputs
struct AppInputs: Sendable {
    let configuration: RuntimeConfiguration
    @Provides(InputKeys.region) let region: String
    @Provides(InputKeys.stage) let stage: String
    var describedRegion: String { "region=\(region)" }
}

/// An ordinary `@Singleton` consuming inputs — by type, and by key through `@Bind`. Read straight off the
/// graph below and injected by nothing, so it declares itself a reachability root.
@Singleton(allowUnused: true)
struct DeploymentTarget: Sendable {
    let summary: String

    @Inject init(
        configuration: RuntimeConfiguration,
        @Bind(InputKeys.region) region: String,
        @Bind(InputKeys.stage) stage: String
    ) {
        self.summary = "\(configuration.endpoint)|\(region)|\(stage)"
    }
}

/// A second consumer, to prove one input reaches more than one binding rather than being moved into the
/// first that asks.
@Singleton(allowUnused: true)
struct EndpointProbe: Sendable {
    let endpoint: String
    @Inject init(configuration: RuntimeConfiguration) { self.endpoint = configuration.endpoint }
}

let graph = try await Wire.bootstrap(
    inputs: AppInputs(
        configuration: RuntimeConfiguration(endpoint: "https://example.test"),
        region: "ap-southeast-2",
        stage: "prod"
    )
)

precondition(
    graph.deploymentTarget.summary == "https://example.test|ap-southeast-2|prod",
    "inputs did not reach the consumer: \(graph.deploymentTarget.summary)"
)
precondition(
    graph.endpointProbe.endpoint == "https://example.test",
    "the same input did not reach a second consumer: \(graph.endpointProbe.endpoint)"
)

print("graph-inputs harness OK — \(graph.deploymentTarget.summary)")
