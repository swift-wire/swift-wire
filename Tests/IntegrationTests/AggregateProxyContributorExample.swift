// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Synchronization
import Wire
import WireTestLibrary

/// The `.contributesAggregateProxy` fixture — one synthesised proxy holding **several** subjects at once,
/// each held or bridged independently. The forcing case is an adapter whose framework demands a single
/// conformer for several user types (WireOpenAPI: `registerHandlers` is emitted once per document and
/// registers every operation from one handler), so the aggregate is what lets a spec be split across
/// controllers. Shape proven by a spike ahead of the synthesis.
///
/// Three subject shapes on one proxy:
///   • `AggregateReportController` — app-scoped `@Singleton`, **held** (`_wireSubject_…`);
///   • `AggregateSearchController<Backend>` — app-scoped and **generic**, held, making the proxy a lift
///     node beside its non-generic peers;
///   • `AggregateTaskController` — `@Scoped(seed:)`, **bridged** through its own
///     `_wireEnterScope_…` thunk.

struct AggregateRequestSeed: Sendable {
    let id: String
}

/// Records constructions so the tests can distinguish per-request rebuilding from app-scoped sharing.
final class AggregateConstructionLog: Sendable {
    static let shared = AggregateConstructionLog()
    private let entries = Mutex<[String]>([])

    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
    func count(_ entry: String) -> Int { entries.withLock { $0 }.filter { $0 == entry }.count }
    func reset() { entries.withLock { $0.removeAll() } }
}

// MARK: - bridged subject

@Scoped(seed: AggregateRequestSeed.self, allowUnused: true)
struct AggregateSessionIdentity: Sendable {
    let userID: String

    @Inject init(seed: AggregateRequestSeed) {
        AggregateConstructionLog.shared.record("session")
        self.userID = "user-\(seed.id)"
    }
}

/// A request-scoped resource with a `@Teardown`, so the aggregate's bridge can be observed tearing down.
/// Records against its *seed*, so an assertion is unaffected by the rest of the suite (every test in this
/// process bootstraps the graph, and these run in parallel).
@Scoped(seed: AggregateRequestSeed.self, allowUnused: true)
final class AggregateRequestResource: Sendable {
    private let seed: AggregateRequestSeed

    @Inject init(seed: AggregateRequestSeed) { self.seed = seed }

    @Teardown
    func close() { AggregateConstructionLog.shared.record("teardown-\(seed.id)") }
}

/// A seed-scoped sibling the bridged subject cannot reach — per-root reachability (per-root reachability) means the
/// aggregate's scope entry must not construct it.
@Scoped(seed: AggregateRequestSeed.self, allowUnused: true)
struct AggregateUnreachableSibling: Sendable {
    @Inject init(seed: AggregateRequestSeed) {
        AggregateConstructionLog.shared.record("unreachable-\(seed.id)")
    }
}

@Scoped(seed: AggregateRequestSeed.self, allowUnused: true)
@AggregateController(spec: "alpha")
struct AggregateTaskController: Sendable {
    @Inject var identity: AggregateSessionIdentity
    @Inject var resource: AggregateRequestResource

    func task(_ id: String) -> String { "task \(id) for \(identity.userID)" }
}

// MARK: - held subjects

// `allowUnused:` for its retention narrowing meaning rather than its diagnostic one: the aggregate reaches this
// binding, so it is constructed either way — the annotation is what keeps it *stored* on the graph, which
// is how `AggregateProxyContributorTests` asserts the aggregate holds the graph's own singleton.
@Singleton(allowUnused: true)
final class AggregateReportStore: Sendable {
    @Inject init() {}
    func all() -> [String] { ["r1", "r2"] }
}

@Singleton
@AggregateController(spec: "alpha")
struct AggregateReportController: Sendable {
    /// Exposed so a test can assert by *identity* that the aggregate holds the graph's own singleton
    /// rather than a fresh construction — the claim a process-global construction count cannot make.
    let store: AggregateReportStore

    @Inject init(store: AggregateReportStore) {
        self.store = store
    }

    func reports() -> String { store.all().joined(separator: ",") }
}

/// Consumes both aggregate keys, so the tests can assert what actually reaches the multibinding: **one**
/// element per aggregate, however many subjects it holds — the whole point of the capability. (It also
/// gives each key a consumer, which Wire otherwise diagnoses.)
@Singleton(allowUnused: true)
struct AggregateContributorHost {
    @Inject(WireTestAggregateKeys.controllers) var controllers: [any Sendable]
    @Inject(WireTestAggregateKeys.soloControllers) var soloControllers: [any Sendable]
}

// MARK: - the one-subject aggregate (compatibility rule)

/// The sole `@SoloAggregateController` subject: a one-member aggregate must keep the **singular** field
/// name `_wireSubject` — positional, exactly as `.contributesProxy` emits — so adopting the aggregate
/// capability changes nothing for an adapter with one subject per proxy.
@Singleton
@SoloAggregateController
struct SoloAggregateOnlyController: Sendable {
    @Inject init() {}
    func solo() -> String { "solo" }
}

// MARK: - held, generic (a lift node beside the non-generic peers)

protocol AggregateSearchBackend: Sendable {
    func find(_ query: String) -> String
}

enum AggregateSearchModule {
    @Provides static func backend() -> some AggregateSearchBackend { AggregateLuceneish() }
}

private struct AggregateLuceneish: AggregateSearchBackend {
    func find(_ query: String) -> String { "hit(\(query))" }
}

@Singleton
@AggregateController(spec: "alpha")
struct AggregateSearchController<Backend: AggregateSearchBackend>: Sendable {
    private let backend: Backend

    @Inject init(backend: Backend) {
        self.backend = backend
    }

    func search(_ query: String) -> String { backend.find(query) }
}

// MARK: - a SECOND group on the same annotation

/// Bearing the same `@AggregateController` but a different `spec`, so it lands on its own proxy —
/// `_WireAggregateContributor_beta` — rather than joining the `alpha` aggregate. This is the multi-spec
/// case: task-cluster's spec lives in one module and its controllers in another, so the group has to be
/// declared at the use site rather than inferred from where the subject lives.
@Singleton
@AggregateController(spec: "beta")
struct BetaOnlyController: Sendable {
    @Inject init() {}
    func beta() -> String { "beta" }
}
