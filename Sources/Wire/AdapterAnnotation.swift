// Public carrier for an adapter-annotation definition.
//
// An adapter package declares one per annotation it publishes (e.g. `@RoutedBy`,
// `@Middleware`, `@ConfigProperty`), stating what the attribute *does* to the declaration
// it sits on via a `WireAdapterCapability`. Wire discovers the declaration syntactically
// (like a `BindingKey` declaration) and never executes it — the capability and any key
// are read from the written syntax, not a runtime value.
//
// Versioned by type: a change to the contract shape ships a new `WireAdapterAnnotationV2`,
// leaving adapters written against V1 working. The build plugin recognises each version by
// its type name.
public struct WireAdapterAnnotationV1: Sendable {
    /// The attribute's spelling without the leading `@` (e.g. `"RoutedBy"`).
    public let annotation: String

    public init(annotation: String, capability: WireAdapterCapability) {
        self.annotation = annotation
    }
}

/// What an adapter annotation does to the declaration it is applied to. One family, so the
/// build plugin has a single recognizer and dispatches the passes off the capability. Not
/// `Sendable` (nor stored): it's a phantom argument read from source syntax, never executed —
/// `contributes(to:)` carries the key value only so the call site reads naturally.
public enum WireAdapterCapability {
    /// `@X` on a binding aliases `@Contributes(to: key)` — collates the binding into a
    /// multibinding key (an *output* edge).
    case contributes(to: Any)

    /// `@X` on a binding contributes a **generated proxy** — not the binding itself — into a
    /// multibinding key. The build plugin synthesises the proxy binding and, at `proxyScope`, either
    /// **holds** the subject (when the subject shares that scope) or **bridges** into it (when the
    /// subject is narrower — e.g. a `@Scoped(seed:)` subject under a `.singleton` proxy: the proxy
    /// holds a scope-entry, constructing the subject on demand from a seed). Either way the proxy
    /// carries any factories the binding's input-edge use-sites demand, conforms to the adapter's
    /// contributor protocol, and the proxy — not the binding — flows into the multibinding. Keeps the
    /// annotated binding an ordinary footgun-free type. `proxyScope` is the scope of the aggregate the
    /// proxy collates into (where it must live to be collected once), and swift-wire compares it
    /// against the subject's scope to pick hold vs bridge.
    case contributesProxy(to: Any, proxyTypePrefix: String, proxyScope: WireProxyScope)

    /// `@X` synthesises a contributor proxy for the annotated declaration — exactly like
    /// `.contributesProxy` (it lifts the declaration's `.injectsFromGraph` peers onto the proxy via
    /// reattribution, leaving the declaration a plain, footgun-free binding) — but contributes it to **no**
    /// multibinding. The proxy is a standalone, directly-addressable graph binding (`graph.<proxy>`); the
    /// adapter's own codegen reads it and emits a method on it. WireMVC's `@WireMVCBootstrap` uses this so a
    /// global `@Middleware` on the composition root synthesises its factories onto a proxy — folded by the
    /// proxy's generated `wrap` method — without injecting them onto the root binding.
    case liftsPeersToProxy(proxyTypePrefix: String, proxyScope: WireProxyScope)

    /// `@X` on **several** bindings contributes ONE generated proxy holding all of them — the *aggregate*
    /// form of `.contributesProxy`. Where `.contributesProxy` synthesises a proxy per subject (named
    /// `<prefix><Subject>`), this synthesises a single proxy named `proxyTypeName` whose fields are every
    /// subject bearing the annotation, each **held or bridged independently**: an app-scoped subject is
    /// stored directly (`_wireSubject_<Subject>`), a narrower `@Scoped(seed:)` subject through its own
    /// scope-entry thunk (`_wireEnterScope_<Subject>`). So one proxy can hold one subject and bridge into
    /// another's request scope. At one subject the field names stay `_wireSubject` / `_wireEnterScope`, so
    /// a single-subject aggregate emits exactly what `.contributesProxy` does.
    ///
    /// The forcing case is an adapter whose framework demands a *single* conformer for several user types
    /// — WireOpenAPI, where the generator's `registerHandlers` is emitted once per document and registers
    /// every operation from one handler, so splitting a spec across controllers needs them behind one
    /// proxy. Wire stays domain-free: it collates the annotated subjects into one synthesised type and
    /// never learns why.
    ///
    /// **`groupedByAttribute` names the use-site argument that partitions the subjects.** One proxy is
    /// synthesised per distinct value — `@X(spec: "TaskAPI")` and `@X(spec: "AdminAPI")` produce
    /// `<proxyTypeName>_TaskAPI` and `<proxyTypeName>_AdminAPI`. Subjects whose attribute omits the
    /// argument share one default group named `proxyTypeName` alone, so an adapter with a single group
    /// needs no argument at all. The value is an opaque key to Wire; an adapter may give it meaning (for
    /// WireOpenAPI it names the module owning the generated `APIProtocol`, which its codegen also needs
    /// to emit the import).
    ///
    /// Grouping cannot be inferred from where the subjects live: task-cluster defines its spec in
    /// `TaskAPI` and its controllers in `TaskClusterApp`, so the owning module is neither the subject's
    /// module nor derivable from it.
    case contributesAggregateProxy(
        to: Any,
        proxyTypeName: String,
        proxyScope: WireProxyScope,
        groupedByAttribute: String
    )

    /// `@X(argument)` on a binding makes the binding depend on a graph value named by `argument` (an
    /// *input* edge), lifted onto the binding's contributor proxy. The **argument's kind** chooses what
    /// is injected:
    /// - a `FactoryKey` → the factory synthesised from the matching `@Factory(key)` template (its box-role
    ///   `create` + `@Inject` dependencies + the injected axis);
    /// - a `BindingKey<T>` → that keyed binding, by key;
    /// - `T.self` → the binding of type `T`, by type.
    ///
    /// So one capability spans the factory, keyed-binding, and by-type cases — the plugin dispatches on
    /// whether the argument is a factory key, a binding key, or a metatype.
    case injectsFromGraph

    /// `@X` / `@X(.role, …)` on a `@Factory` template supplies the **role mapping** for the
    /// factory's assisted (non-`@Inject`-typed) generic parameters. `roles` is the adapter's ordered
    /// vocabulary of canonical slot names (e.g. `["RequestContext", "Reader", "ResponseSender"]`), read
    /// by the plugin as **opaque ordered identifiers** — it names the synthesised `create`'s generic
    /// parameters and, at the call site, the fixed order the consumer's macro passes them in. A bare
    /// `@X` maps the template's assisted parameters to these roles *by order*; `@X(.a, .b, …)` maps them
    /// *by the listed roles* (positional over the assisted parameters, referenced `.` + the role name
    /// lower-cameled). Producer-side, joined to the template by type identity.
    case mapsFactoryRoles(roles: [String])

    /// `@X(...)` on a consumer's injection point rewrites how that dependency resolves — the annotated
    /// site stops resolving by its own type and instead resolves to a binding Wire synthesises, which
    /// reads the value out of a *provider* the graph supplies (e.g. `@ConfigProperty(forKey: "PORT")`
    /// reading a `ConfigReader`).
    ///
    /// Wire emits, for a site of type `T` annotated `@X(a, b)`:
    ///
    ///     private func _wireRewrite_…(_wireProvider: <provider>) throws -> T {
    ///         try X<T>.wireValue(from: _wireProvider, a, b)
    ///     }
    ///
    /// — copying the annotation's argument list **verbatim**, so it never learns what the value means, how
    /// it is read, or which method reads it. `provider` names the binding the value is read from, as
    /// written (`"ConfigReader"`); Wire matches dependencies by canonical type text and cannot infer it.
    ///
    /// The annotation is declared **twice under one name**, and Swift resolves each use site to whichever
    /// can apply there:
    ///
    /// - a **property wrapper**, the only mechanism that can attach to a parameter, supplying
    ///   `init(wrappedValue:…)` per supported shape — a parameter site always has a value to pass, so
    ///   these need carry nothing else;
    /// - a **peer macro** generating nothing, the only mechanism that can attach to a `let` property
    ///   (`property wrapper can only be applied to a 'var'`), and which `var` properties resolve to as
    ///   well.
    ///
    /// Resolution itself is a **static** `wireValue(from:…)` on the wrapper, one overload per shape. It is
    /// deliberately not a protocol requirement: its signature is whatever the annotation's arguments are,
    /// which no protocol can express — and the same is already true of the initialisers. A missing
    /// overload is an adapter-authoring bug caught the first time the annotation is wired.
    case rewritesInjection(provider: String)
}

/// The scope at which a `.contributesProxy` proxy is emitted — the scope of the multibinding
/// aggregate it collates into, which is where the proxy must live to be collected and applied.
/// swift-wire compares it against the *subject's* scope: same scope → the proxy **holds** the
/// subject; the subject narrower → the proxy **bridges** into the subject's scope (a
/// `@Scoped(seed:)` subject under a `.singleton` proxy is a sanctioned scope bridge, not a
/// cross-scope violation). `.singleton` is the value for every collating adapter today (collation
/// happens at app scope); a seeded proxy scope is reserved for a future per-request-collation case.
public enum WireProxyScope: Sendable {
    /// The proxy is app-scoped — built once and collated into the app graph.
    case singleton
}
