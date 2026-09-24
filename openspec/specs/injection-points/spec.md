# Injection points

## Purpose

The places a type declares what it depends on, and how each is delivered. `@Inject` is a marker
that the lifetime macro reads to synthesise an initialiser and that WireGen reads to discover
dependencies. Constructor injection covers `@Inject` stored properties and a single user-written
`@Inject init`; post-construction member injection covers `@Inject weak var` and `@Inject func`.
The `@Bind(key)` property wrapper keys an initialiser or provider parameter, where a macro
attribute cannot go.

Rationale: [WeakInjectionSupport](../../../Documentation/Notes/WeakInjectionSupport.md), [VisibilityModel](../../../Documentation/Notes/VisibilityModel.md), [OptionalMatchingAndCycles](../../../Documentation/Notes/OptionalMatchingAndCycles.md).
Documentation: [InjectionPoints](../../../Sources/Wire/Wire.docc/InjectionPoints.md).

## Requirements

### Requirement: `@Inject` stored properties become the synthesised initialiser's parameters
When the primary declaration of a `@Singleton`, `@Scoped` or `@Factory` type has no user-written
initialiser, the macro SHALL generate `init(<name>: <Type>, …)` taking one parameter per
type-annotated `@Inject` stored-property binding in declaration order, assigning each with
`self.<name> = <name>`, or `init()` when there are none. A binding without its own annotation, such
as `a` in `@Inject var a, b: Dep`, gets no parameter, which is tracked as a possible defect in
https://github.com/swift-wire/swift-wire/issues/411. The generated `init` SHALL carry the host
type's access keyword verbatim, omitting `internal`; for an `open` host that is `open init`, which
Swift rejects, tracked in https://github.com/swift-wire/swift-wire/issues/407.

#### Scenario: one injected property
- **WHEN** `@Singleton struct A { @Inject var b: B }` is expanded
- **THEN** the expansion adds `init(b: B) { self.b = b }` and `static let key = BindingKey<A>()`

#### Scenario: a public host
- **WHEN** `@Singleton public struct` declares `@Inject` properties
- **THEN** the synthesised initialiser is declared `public init(…)`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonWithOneInject_generatesParameterisedInit`, `test_singletonWithMultipleInjects_preservesDeclarationOrder`, `test_singletonOnPublicStruct_emitsPublicInitAndKey`), `Tests/WireMacrosImplTests/FactoryMacroTests.swift` (`test_factoryWithInjectProperty_generatesInitFromInjectMembers`).

### Requirement: A constructor-injected property may be `private`
WireGen SHALL NOT raise an access-level error for a constructor-injected `@Inject` property
(an owning `var`/`let`, a `weak let`, or an `unowned` property), whatever its access modifier,
because the generated bootstrap only calls the macro-generated initialiser.

#### Scenario: a private `weak let`
- **WHEN** a `@Singleton` class declares `@Inject private weak let coordinator: Coordinator?`
- **THEN** discovery reports no declaration-too-private error

#### Scenario: a private owning property
- **WHEN** a `@Singleton` declares `@Inject private var logger: Logger`
- **THEN** discovery reports no declaration-too-private error

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateWeakInjectLetEmitsNoTooPrivateError`). The private owning property scenario is pinned by nothing yet.

### Requirement: A user-written initialiser must be the single `@Inject init`
When the primary declaration has any user-written initialiser, the macro SHALL NOT synthesise
one, and exactly one initialiser SHALL carry `@Inject`. Each unmarked initialiser, when none is
marked, SHALL be diagnosed with the error "User-provided initialiser must be marked @Inject so
Wire knows which one to call. Either add @Inject to this initialiser, or remove the initialiser
entirely and let Wire generate one from @Inject stored properties." Each of two or more marked
initialisers SHALL be diagnosed with "Only one initialiser can be marked @Inject. Remove @Inject
from the others."

#### Scenario: an unmarked initialiser
- **WHEN** `@Singleton struct A` declares `init(b: B)` with no `@Inject`
- **THEN** the macro reports the unmarked-user-init error at that initialiser

#### Scenario: two marked initialisers
- **WHEN** a `@Singleton` declares two initialisers, both marked `@Inject`
- **THEN** the macro reports "Only one initialiser can be marked @Inject. Remove @Inject from the others." at each

#### Scenario: one marked among several
- **WHEN** a `@Singleton` declares two initialisers and marks one `@Inject`
- **THEN** the expansion adds only the `static key` and no diagnostic

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonReportsUnmarkedUserInit`, `test_singletonReportsUnmarkedParameterlessInit`, `test_singletonReportsMultipleInjectInits`, `test_singletonAllowsMultipleInitsWithOneMarked`, `test_singletonSkipsInitGenerationWhenInjectInitProvided`).

### Requirement: `@Inject` on both an initialiser and a stored property is an error
When one initialiser is marked `@Inject` and any stored property that would be a constructor
injection point (an owning property, a `weak let`, or an `unowned` property; that is, any
`@Inject` property except a `weak var`) is also marked `@Inject`, the macro SHALL
report "@Inject is on both an initialiser and a stored property. Pick one source of truth — either
the @Inject-marked initialiser declares dependencies via its parameters, or @Inject-marked
properties declare them via Wire's auto-generated init." at the initialiser. An `@Inject weak var`
SHALL NOT trigger this error.

#### Scenario: init and owning property
- **WHEN** a `@Singleton struct A` declares `@Inject var b: B` and `@Inject init(b: B)`
- **THEN** the macro reports the inject-on-init-and-property error

#### Scenario: init and `weak var`
- **WHEN** a `@Singleton` class declares `@Inject weak var coordinator: Coordinator?` and `@Inject init(name: String)`
- **THEN** the expansion adds only the `static key` and no diagnostic

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_singletonReportsInjectOnInitAndProperty`, `test_injectWeakVar_coexistsWithStrongInjectInit`), `Tests/WireMacrosImplTests/WireDiagnosticTests.swift` (`test_injectOnInitAndProperty_diagnosticID`).

### Requirement: An `@Inject init` must be at least `internal`
WireGen SHALL report an error "@Inject init is '<keyword>' but must be at least 'internal' — Wire's
generated bootstrap calls this initialiser from a separate file. Change to 'internal', 'package',
or 'public'." at an `@Inject init` declared `private` or `fileprivate`.

#### Scenario: a private initialiser
- **WHEN** a `@Singleton` declares `@Inject private init(logger: Logger) {}`
- **THEN** discovery reports the error naming `'private'`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateInjectInitEmitsDeclarationTooPrivateError`).

### Requirement: `@Inject weak var` is delivered after construction
On a `@Singleton` or `@Scoped` class host, an `@Inject weak var` property, declared `T?` or `T!`,
SHALL be excluded from the synthesised initialiser's parameters and recorded as a post-construction
property-assignment member injection, and the generated bootstrap SHALL assign it with
`<consumer>.<property> = <producer>` after the construction sequence. An actor host goes through the
generated setter in the next requirement. On a `@Factory` template the property is never assigned,
tracked as a possible defect in https://github.com/swift-wire/swift-wire/issues/409; on a struct host
the emitted assignment targets a `let` local, tracked in
https://github.com/swift-wire/swift-wire/issues/410.

#### Scenario: the synthesised init omits the weak property
- **WHEN** `@Singleton final class View { @Inject weak var coordinator: Coordinator? }` is expanded
- **THEN** the expansion adds `init() { }`

#### Scenario: the bootstrap assigns it
- **WHEN** `View` holds `@Inject weak var coordinator: Coordinator?` and `Coordinator` takes `View` in its `@Inject init`
- **THEN** the bootstrap builds both and then runs `view.coordinator = coordinator`, and `graph.view.coordinator === graph.coordinator`

#### Scenario: the IUO spelling
- **WHEN** `Spoke` declares `@Inject weak var hub: Hub!`
- **THEN** bootstrap succeeds and `graph.spoke.hub === graph.hub`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_injectWeakVar_excludedFromSynthesisedInitParameters`, `test_injectWeakVarAlongsideStrongInjectVar_synthesisesInitForStrongOnly`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`weakInjectVarBecomesPropertyAssignmentMemberInjection`, `weakInjectVarWithIUOBecomesPropertyAssignmentMemberInjection`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentMemberInjectionEmitsAsDirectAssignmentAfterConstruction`), `Tests/IntegrationTests/BootstrapTests.swift` (`weakInjectionBreaksSingletonCycle`, `weakInjectionEstablishesPostInitReferenceWithoutRetainCycle`, `iuoWeakVarBreaksSingletonCycle`) over `Tests/IntegrationTests/WeakCycleExample.swift` and `Tests/IntegrationTests/IUOWeakCycleExample.swift`.

### Requirement: An `@Inject weak var` must be writable from the generated bootstrap
WireGen SHALL report an error "@Inject weak var '<name>' is '<keyword>' but must be at least
'internal' — Wire's generated bootstrap assigns to this property post-construct and lives in a
separate file. Change to 'internal', 'package', or 'public'." for a `private` or `fileprivate`
`@Inject weak var`, with the post-construct asymmetry note. It SHALL report "@Inject weak var
'<name>' setter is '<keyword>(set)' but must be at least 'internal' — …" for a `private(set)` or
`fileprivate(set)` setter, with the note "Drop the setter restriction to inherit the property's
read access, or use 'internal(set)' / higher if a narrower setter is required."

#### Scenario: a private weak var
- **WHEN** a `@Singleton` class declares `@Inject private weak var coordinator: Coordinator?`
- **THEN** the rendered output contains `error: @Inject weak var 'coordinator' is 'private'` and a `note:` beginning `'@Inject var' / '@Inject let' (non-weak) can be 'private' because the macro generates the init within the host type's scope`

#### Scenario: a restricted setter
- **WHEN** a `@Singleton` class declares `@Inject public private(set) weak var coordinator: Coordinator?`
- **THEN** the rendered output contains `@Inject weak var 'coordinator' setter is 'private(set)'` and a note beginning `Drop the setter restriction`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`privateInjectWeakVarRendersWithAsymmetryNote`, `privateSetOnInjectWeakVarRendersWithDropSetterNote`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateInjectWeakVarEmitsErrorWithAsymmetryNote`, `privateSetOnPublicInjectWeakVarEmitsSetterRestrictionError`).

### Requirement: An actor's `@Inject weak var` is assigned through a generated setter
For an `@Inject weak var <property>` on an `actor` host, WireGen SHALL emit
`extension <Actor> { func _wireSet<Property>(_ value: <declared type>) { self.<property> = value } }`,
once per actor type and property, and the bootstrap SHALL call
`await <consumer>._wireSet<Property>(<producer>)` in place of a direct assignment.

#### Scenario: the emitted setter
- **WHEN** actor `Toolbelt` declares `@Inject package weak var workshop: Workshop?`
- **THEN** the generated source contains `await toolbelt._wireSetWorkshop(workshop)` and `extension Toolbelt { func _wireSetWorkshop(_ value: Workshop?) {` with body `self.workshop = value`

#### Scenario: two actors in a cycle
- **WHEN** actor `Workshop` takes `Toolbelt` in its `@Inject init` and actor `Toolbelt` declares `@Inject weak var workshop: Workshop?`
- **THEN** bootstrap succeeds and `await graph.toolbelt.workshop === graph.workshop`

Pinned by: `GoldenHarness/Golden/_WireGraph.swift.golden` (`_wireSetWorkshop`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`propertyAssignmentOnActorConsumerRoutesThroughGeneratedSetterExtension`), `Tests/IntegrationTests/BootstrapTests.swift` (`weakInjectionOnActorRoutesThroughGeneratedSetterExtension`) over `Tests/IntegrationTests/ActorWeakCycleExample.swift`.

### Requirement: `weak let` and `unowned` properties are constructor-injected
An `@Inject weak let` property SHALL be a synthesised-initialiser parameter of its declared optional
type, and an `@Inject unowned` property SHALL be one of its declared non-optional type. Both SHALL
be init-time dependencies (not member injections), flagged as non-owning so a dependency cycle
through them can name them, and neither SHALL produce a diagnostic when acyclic.

#### Scenario: `weak let` in the synthesised init
- **WHEN** `@Singleton final class View { @Inject weak let coordinator: Coordinator? }` is expanded
- **THEN** the expansion adds `init(coordinator: Coordinator?) { self.coordinator = coordinator }`

#### Scenario: `weak let` end to end
- **WHEN** `Dashboard` declares `@Inject package weak let telemetry: Telemetry?` and `Telemetry` is a `@Singleton`
- **THEN** `graph.dashboard.telemetry === graph.telemetry`

#### Scenario: `unowned let` end to end
- **WHEN** `Monitor` declares `@Inject package unowned let sensor: Sensor` and `Sensor` is a `@Singleton`
- **THEN** `graph.monitor.sensor === graph.sensor`

Pinned by: `Tests/WireMacrosImplTests/SingletonMacroTests.swift` (`test_injectWeakLet_includedInSynthesisedInitParameters`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`weakInjectLetBecomesInitDependencyNotMemberInjection`, `weakInjectLetEmitsNoBlanketDiagnostic`, `weakInjectLetWithIUOBecomesInitDependency`, `unownedInjectBecomesInitDependencyFlaggedNonOwning`), `Tests/IntegrationTests/BootstrapTests.swift` (`weakLetInjectionDeliversNonOwningReferenceAtInit`, `unownedInjectionDeliversNonOwningReferenceAtInit`) over `Tests/IntegrationTests/WeakLetExample.swift` and `Tests/IntegrationTests/UnownedExample.swift`.

### Requirement: `@Inject func` is called after construction
Each `@Inject func` on a `@Singleton` or `@Scoped` type, other than an `@Inject mutating func` on a
struct (see below), SHALL be recorded as a method-call member injection whose parameters resolve through the graph. The bootstrap SHALL call it after the
construction sequence as `[try] [await] <consumer>.<method>(<args>)`, with `try` when the method
throws and `await` when the method is `async` or the host is an `actor`.

#### Scenario: a class host
- **WHEN** `NoteBoard` declares `@Inject package func receive(message: NoteMessage)` and a `NoteMessage` is provided
- **THEN** after bootstrap `graph.noteBoard.current() == "wire said: hello from @Inject func"`

#### Scenario: an async throwing method
- **WHEN** `View` declares an `@Inject func setup(db: Database) async throws`
- **THEN** the generated bootstrap contains `try await view.setup(db: database)`

#### Scenario: a synchronous method on an actor
- **WHEN** actor `TickCounter` declares a synchronous `@Inject package func bump(by amount: TickIncrement)`
- **THEN** the call is emitted with `await`, and after bootstrap `await graph.tickCounter.ticks == 7`

Pinned by: `Tests/WireGenCoreTests/DiscoveryTests.swift` (`injectFuncBecomesMethodCallMemberInjection`, `injectFuncCapturesEffectSpecifiers`), `Tests/WireGenCoreTests/CodeEmissionTests.swift` (`methodCallMemberInjectionEmitsAsMethodCallAfterConstruction`, `asyncThrowingMethodCallInjectionGetsTryAwaitPrefix`, `methodCallOnActorConsumerForcesAwaitEvenForSyncMethod`, `throwingMethodCallOnActorConsumerGetsTryAwaitPrefix`), `Tests/IntegrationTests/BootstrapTests.swift` (`injectFuncRunsAfterConstructionAndWiresState`, `injectFuncOnActorConsumerRunsThroughActorIsolation`) over `Tests/IntegrationTests/MethodInjectionExample.swift` and `Tests/IntegrationTests/ActorMethodInjectionExample.swift`.

### Requirement: An `@Inject func` must be at least `internal`
WireGen SHALL report an error "@Inject func '<name>' is '<keyword>' but must be at least 'internal' —
Wire's generated bootstrap calls this method post-construct and lives in a separate file. Change to
'internal', 'package', or 'public'." for a `private` or `fileprivate` `@Inject func`, with the
post-construct asymmetry note.

#### Scenario: a private method
- **WHEN** a `@Singleton` class declares `@Inject private func receive(data: Data) {}`
- **THEN** the rendered output contains `View.swift:3:26: error:` and `@Inject func 'receive' is 'private'` followed by a `note:`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`privateInjectFuncRendersWithAsymmetryNote`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`privateInjectFuncEmitsErrorWithAsymmetryNote`).

### Requirement: `@Inject mutating func` on a struct is an error
WireGen SHALL report an error beginning "'@Inject mutating func' on a struct produces divergent
state — consumers that received this binding via init see the pre-mutation value, only the
graph-stored value reflects the mutation." at the method name of an `@Inject mutating func` on a
`struct` host, and SHALL record no member injection for it. A non-mutating `@Inject func` on a
struct, or any `@Inject func` on a class, SHALL NOT be diagnosed.

#### Scenario: a mutating method on a struct
- **WHEN** `@Singleton struct Config` declares `@Inject mutating func receive(data: SomeData)`
- **THEN** the rendered output contains `Config.swift:4:19: error:` and the fixes "convert to a class", "drop 'mutating'" and "@Inject init"

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`mutatingInjectFuncOnStructRendersAsErrorWithFixIts`), `Tests/WireGenCoreTests/DiscoveryTests.swift` (`mutatingInjectFuncOnStructEmitsErrorDiagnostic`, `mutatingInjectFuncOnClassDoesNotEmitDiagnostic`, `nonMutatingInjectFuncOnStructIsAllowed`).

### Requirement: Member-injection parameters are resolved but form no graph edge
The parameters of `@Inject weak var` and `@Inject func` member injections SHALL be matched against
the graph like init-time dependencies, and an unmatched one SHALL be reported as a missing binding.
They SHALL NOT be added to the dependency edges that drive the topological sort and cycle detection.

#### Scenario: an unbound weak dependency
- **WHEN** `A` declares a weak member injection of `B` and nothing binds `B`
- **THEN** the graph reports one missing binding whose dependency type is `B`

Pinned by: `Tests/WireGenCoreTests/GraphTests.swift` (`missingBindingDetectionFiresForWeakDeps`, `cycleThroughWeakInjectIsLegal`).

### Requirement: `@Bind(key)` keys an initialiser or provider parameter
`Bind<Value>` SHALL be a `@propertyWrapper` whose `wrappedValue` is the parameter's value, with
initialisers taking a `BindingKey<Value>`, a `CollectedKey<Element>` (where `Value == [Element]`),
a `MappedKey<Key, Element>` (where `Value == [Key: Element]`) and a `BuilderKey<Builder>`. WireGen
SHALL read the key of `@Bind(<key>)` on an `@Inject init` or `@Provides func` parameter as that
dependency's key, and the generated bootstrap SHALL pass the keyed binding's value under the
parameter's label, as for an unkeyed parameter.

#### Scenario: a keyed single binding
- **WHEN** `KeyedInitConsumer` declares `@Inject init(@Bind(AppName.boundViaInit) name: AppName)` and `@Provides(AppName.boundViaInit)` binds `AppName(value: "bound-via-init")`
- **THEN** `graph.keyedInitConsumer.describe() == "init consumer with bound-via-init"` while the unkeyed `graph.appName.value == "IntegrationTests"`

#### Scenario: discovery reads the key
- **WHEN** a `@Singleton` declares `@Inject init(@Bind(Database.primary) db: Database, logger: Logger)`
- **THEN** the `db` dependency's key is `Database.primary` and the `logger` dependency is unkeyed

#### Scenario: aggregates through parameters
- **WHEN** a `@Provides func formatterChain(@Bind(FormatterKeys.all) formatters: [any Formatter])` and an `@Inject init(@Bind(FormatterKeys.byName) byName: [String: any Formatter], chain: FormatterChain)` are declared
- **THEN** the IntegrationTests target's generated graph compiles with both aggregates passed to those parameters

Pinned by: `Tests/IntegrationTests/BootstrapTests.swift` (`keyedInitParameterInjectsTheMatchingKeyedProvider`) over `Tests/IntegrationTests/KeyedInitParameterExample.swift`, `Tests/WireGenCoreTests/DiscoveryTests.swift` (`injectInitParameterWithBindKeyExtractsCanonicalText`), `Tests/IntegrationTests/BindAggregateParameterExample.swift` (compiled with the IntegrationTests target). The `BuilderKey` overload is pinned by nothing yet.

### Requirement: `@Inject` on members of a type no macro reads is a warning
When a type carries none of `@Singleton`, `@Scoped` or `@Factory`, WireGen SHALL warn at each
`@Inject` stored-property binding "@Inject on '<name>' has no effect — nothing on '<Type>' reads it.
Add @Singleton, @Scoped(seed:) for a seeded scope, or @Factory(key) for a factory template, to enable
wiring." and at an `@Inject init` "@Inject on this initialiser has no effect — nothing on '<Type>'
reads it. …" with the same remedy.

#### Scenario: a plain struct
- **WHEN** `struct Plain { @Inject var logger: Logger }` is discovered
- **THEN** the rendered output contains `Plain.swift:2:5: warning:` and `@Inject on 'logger' has no effect`

#### Scenario: a factory template
- **WHEN** `@Factory(CORSKeys.factory) struct CORSMiddleware<Ctx, Reader, Sender> { @Inject var configuration: CORSConfiguration }` is discovered
- **THEN** no stray-`@Inject` warning is reported

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`strayInjectOnNonScopeTypeMemberRendersAsDiagnostic`), `Tests/WireGenCoreTests/StrayInjectDiagnosticTests.swift` (`straySites`, `strayInitialiser`, `messageNamesTheOptions`, `scopeMacrosAreSilent`, `factoryTemplateIsSilent`).

### Requirement: `@Inject` at module scope is a warning
WireGen SHALL warn "@Inject on '<name>' at module scope has no effect — use @Provides for
module-scope bindings." at a module-scope variable marked `@Inject`.

#### Scenario: a module-scope let
- **WHEN** `@Inject let logger: Logger = Logger()` is declared at file scope
- **THEN** the rendered output contains `Logger.swift:1:1: warning:` and `@Inject on 'logger' at module scope has no effect`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`strayInjectAtModuleScopeRendersAsDiagnostic`).

### Requirement: `@Inject init` in an extension is a warning
WireGen SHALL warn "@Inject on an extension init has no effect — move the init into the primary
declaration of '<Type>' so the @Singleton macro can see it." at each `@Inject init` declared in an
extension.

#### Scenario: an extension initialiser
- **WHEN** `extension Foo { @Inject init(custom: String) {} }` extends a `@Singleton struct Foo`
- **THEN** the rendered output contains `warning: @Inject on an extension init has no effect` naming `'Foo'`

Pinned by: `Tests/WireGenCoreTests/DiagnosticGalleryTests.swift` (`injectInitInExtensionRendersAsDiagnostic`).

## Related specifications

- [dependency-cycles](../dependency-cycles/spec.md)
- [optional-promotion](../optional-promotion/spec.md)
- [binding-lifetimes](../binding-lifetimes/spec.md)
- [binding-identity-and-keys](../binding-identity-and-keys/spec.md)
- [visibility-and-access](../visibility-and-access/spec.md)
- [teardown](../teardown/spec.md)
