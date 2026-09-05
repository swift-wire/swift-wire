# Writing an adapter

How a third-party package teaches Wire to wire something Wire knows nothing about — routes,
configuration values, queue consumers — without a change to Wire itself.

## Overview

The Wire core defines a fixed vocabulary: the lifetime macros, [`@Inject`](doc:Inject()),
``Bind``, [`@Provides`](doc:Provides(allowUnused:)), [`@Container`](doc:Container()),
[`@GraphInputs`](doc:GraphInputs()),
[`@Contributes`](doc:Contributes(to:)-(CollectedKey<Element>)), [`@Teardown`](doc:Teardown()),
[`@Replaces`](doc:Replaces()), ``Lazy``, and the key types. Every framework integration lives
outside that, as an **adapter annotation**: a macro your package publishes that the build
plugin recognises.

The critical property is what an adapter annotation *is not*. It does not emit registration
code, and Wire never learns what it means. It declares a **capability** — one edge Wire adds to
the graph around the declaration the attribute sits on. Wire performs that edge; your own macro
does the framework work in its own expansion, where Wire never looks.

That split is the whole contract, and it is why adding a routing package requires no change to
Wire: the core learns that a binding gained a contribution or a dependency, never that the thing
is a route.

## Declaring an annotation

One declaration per annotation you publish:

```swift
public let controllerAnnotation = WireAdapterAnnotationV1(
    annotation: "Controller",                    // the spelling, without `@`
    capability: .contributesProxy(
        to: MyKeys.routeContributors,            // a key your package owns
        proxyTypePrefix: "_WireRouteContributor_",
        proxyScope: .singleton
    )
)
```

Wire reads this **syntactically**, exactly as it reads a ``BindingKey`` declaration. The plugin
parses your source and never runs it, so the key argument is captured as written text rather
than as a runtime value. Nothing registers itself and there is no initialisation order to think
about.

## The capability axis

Every case in ``WireAdapterCapability`` is domain-free: it names *what edge* is synthesised,
never what the value means.

| Capability | The edge |
|---|---|
| `.contributes(to:)` | **Output.** The binding flows into the key's aggregate — the annotation aliases `@Contributes(to:)`. |
| `.contributesProxy(to:…)` | **Output, one generated proxy per subject.** The proxy collates, not the binding, so the annotated type stays an ordinary value. |
| `.contributesAggregateProxy(to:…, groupedByAttribute:)` | **Output, one proxy over many subjects**, partitioned by a use-site argument. For a framework demanding a single conformer where the user has several types. |
| `.liftsPeersToProxy(…)` | A proxy synthesised and directly addressable, contributing to **no** key — your codegen emits onto it. |
| `.injectsFromGraph` | **Input.** `@X(argument)` makes the binding depend on a graph value named by the argument. |
| `.mapsFactoryRoles(roles:)` | Supplies the ordered role names for a [`@Factory`](doc:Factory(_:)) template's assisted generic parameters, read as opaque identifiers. |
| `.rewritesInjection(provider:selector:)` | The annotated *injection point* stops resolving by its own type and resolves instead to a binding Wire synthesises, which reads the value from a provider the graph supplies. |

### Proxies, and why they exist

`.contributesProxy` is the case worth understanding, because it is doing something subtler than
collation. The proxy — not your user's type — is what flows into the multibinding, which keeps
the annotated type an ordinary, footgun-free value. At `proxyScope`, Wire compares the proxy's
scope against the subject's and either **holds** the subject (same scope) or **bridges** into it
(subject narrower: the proxy holds a scope entry and constructs the subject on demand from a
seed). A request-scoped controller under an app-scoped proxy is a sanctioned bridge, not a
cross-scope violation — and it is what lets a per-request type be collated once at startup.

``WireProxyScope`` is `.singleton` for every collating adapter today, since collation happens at
app scope.

### How little Wire is told

`.rewritesInjection` is the clearest illustration. For a site of type `T` annotated `@X(a, b)`,
Wire emits a producer calling `X<T>.wireValue(from: <provider>, a, b)` — copying your argument
list **verbatim**. It never learns what a key is, which method reads it, or that a "default" or
a "secret" is a thing. Supporting a new value type is adding an overload in your package, not a
case in Wire.

``WireProviderSelector`` is the single place Wire stops copying verbatim: it names the argument
*label* carrying the provider's key, so a graph with more than one provider can say which to
read from. It is identified by label rather than position because an annotation whose own first
argument is unlabelled would otherwise be indistinguishable from one leading with a selector.

## Where the attribute attaches

Independently of the capability, an annotation attaches in one of three places, and the contract
supported all three from the start because retrofitting the third would have broken every
adapter written against the first two:

- **Type-level.** The attribute on a type.
- **Type-level with member recognition.** The attribute on the type, with your own vocabulary on
  its members — verbs, paths, response shapes. Wire's scan never matches those; they are private
  to your package, so the core stays ignorant of routing while your plugin walks the same source.
- **Member- or parameter-level.** On a property, an `@Inject` property, or an `@Inject init`
  parameter.

## The three pieces of the contract

**1. You declare the annotation, own the key, and ship a facade.** The key is an ordinary
multibinding key; the facade consumes its product and applies it to a framework object — a
router, a transport — that stays *outside* the graph.

**2. The consumer activates you by depending on you.** The plugin re-parses the sources of each
Wire-aware library the target directly depends on and finds the declarations there. Discovery is
name-agnostic: the module defining an annotation is usually not the module using it.

**3. The plugin synthesises the declared edge, and everything after that is ordinary
machinery.** A `.contributes` annotation becomes a synthetic contribution flowing through the
same fan-in a hand-written one uses; an `.injectsFromGraph` annotation appends a dependency. No
bespoke emission, no adapter-specific phase.

Validation stays structural: an unbound dependency is a compile error pointing at the annotation
that asked for it, and a key with no contributors yields an empty aggregate rather than a
missing member.

## Collation, not registration

This is the decision the contract turns on, and the design it replaced is worth naming because
it is the obvious one.

The first model made an adapter a **post-construction sink**: the annotation generated a
`register(instance:router:)` member that Wire called after the graph was built. It worked, and
it cost. The router had to be a binding, so a consumer of the *mutated* router had to be ordered
after registration, so there had to be a phase taxonomy, so the contract had to version its
phases. It also needed a bespoke dead-binding exemption, since a registered subject nothing
injected looked unused.

Collation inverts it. The framework object leaves the graph, the annotation aliases a
contribution, and the contributor flows through machinery that already existed. Nothing in the
graph consumes a mutated collaborator, so there is no ordering problem, no phase and no
exemption — the contribution *is* the consumption edge.

## Reading the graph without naming it

A facade needs the collated products but must not name the generated graph type, which is
internal to the consumer. Declare a conformance instead:

```swift
public let conformance = WireGraphConformanceV1(
    conformsTo: (any MyComposable).self,
    members: [.init("routes", from: MyKeys.routes)]
)
```

Wire emits the conformance on the generated graph, maps each member to its key's aggregate, and
infers the protocol's associated types from the witnesses. Your facade then takes
`some MyComposable`. Wire still knows nothing about what the protocol means — the same reason
``Introspectable`` and ``Teardownable`` are shaped the way they are.

## Versioning

The contract is **versioned by type name**. A shape change ships `WireAdapterAnnotationV2`
beside `WireAdapterAnnotationV1`, and the plugin recognises each by its type, so adapters written
against V1 keep working with no shim to maintain.

Adding a *capability* is not a version bump at all: the enum grows a case, and an adapter not
using it is unaffected. Where a case's own payload might need to grow, it is a struct with a
static factory rather than an enum — which is why ``WireProviderSelector`` is shaped as it is —
so a second form can arrive without breaking an exhaustive `switch` in an adapter that inspects
one.

## Public API and SPI

Two stability tiers, and it is worth knowing which side of the line you are building on:

- **Public API** — stable, and a breaking change means a major version:
  `WireAdapterAnnotationV1` and ``WireAdapterCapability``, `WireGraphConformanceV1`, the key
  types, ``Introspectable`` and the introspection model, ``Teardownable``, and
  [`@Teardown`](doc:Teardown()).
- **SPI** — adapter authors only, and free to evolve within a major version: the names and
  internal shape of generated proxies, the generated bootstrap structure, plugin internals, and
  the scope-entry types your codegen reads.

Building against the public tier insulates you from Wire's internal evolution.
