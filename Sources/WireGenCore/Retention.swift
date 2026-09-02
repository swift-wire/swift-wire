// Retention — what the generated graph *stores*, as opposed to what it constructs (M7c.1).
//
// M7b answered "which bindings does this graph build?"; this file answers the different question
// "which of them does it hold a reference to afterwards?". Until M7c.1 the two were the same — one
// stored property per binding — and that is the property `Documentation/Notes/ConstructionScheduling.md`
// § "Step 1 — narrow what the graph retains" removes.
//
// Why it matters beyond struct size: **retention is what makes a value un-transferable.** A binding the
// graph stores is still live when construction finishes, so it can never be moved into its consumer, and
// a non-Sendable one can therefore never be moved into a child task. Narrowing retention is what buys
// the later sub-steps their non-Sendable and noncopyable support; it is not a size optimisation that
// happens to come first.
//
// The retained set is the M7b root model plus three additions the roots do not cover, each of which is a
// place something *other than a consumer* holds the value:
//
//   1. **`@Teardown` bindings.** `bootstrapTeardownClosureLines` captures each one's concrete local, so
//      the closure retains it whatever this file decides — dropping the property would buy no
//      transferability, and would take `graph.x` away from exactly the resources users most often read.
//      Note the deliberate collision with M7b: `@Teardown` does **not** root a binding for *reachability*
//      (a resource nothing reaches is never built, so there is nothing to shut down), but it does retain
//      one that is built. Same annotation, opposite answers, because they are different questions.
//   2. **Opaquely-bound (`some P`) bindings.** These lift a generic parameter onto the struct, so the
//      graph's *type* names them — `_WireGraph<some Greeting, …>`, which every seed scope's `wireGraph:`
//      parameter and every bootstrap return type spells. Dropping one is a surface change to the graph's
//      type identity rather than a retention change, so M7c.1 leaves the lift set alone; the binding is
//      retained by the type either way.
//   3. **Anything read off the graph by generated code** — seed-scope façade borrows, contributor-proxy
//      facades, seedless reconstruction, and graph-conformance members. See `graphPropertyReads`.
//
// Everything else becomes a bootstrap local only. A multi-consumer binding still needs *frame* retention
// — it is a `let` the consumers share — but that is the bootstrap's business, not the graph's.

/// The property names `structName`'s emitted graph must keep as stored properties.
///
/// Named by property rather than by `BindingIdentity` because that is the currency of the three
/// read-sites this has to agree with: generated code reads `_wireGraph.<property>`, and the user reads
/// `graph.<property>`. Identity would have to be mapped back to a name at every comparison.
///
/// `roots` is `declaredRoots`' output for this graph — the M7b root model, unchanged and deliberately
/// reused rather than re-derived, so "what the graph keeps" cannot drift from "what the graph builds
/// because nothing else would".
package func retainedPropertyNames(
    in topologicalOrder: [DiscoveredBinding],
    roots: Set<BindingIdentity>,
    readOffGraph: Set<String>
) -> Set<String> {
    var retained = readOffGraph
    for binding in topologicalOrder {
        let isRetained =
            roots.contains(binding.identity)
            || binding.teardown != nil
            || binding.boundType.hasPrefix("some ")
        if isRetained { retained.insert(propertyName(for: binding)) }
    }
    return retained
}

/// Every property name generated code reads off a graph value, and the property names each graph's own
/// conformance witnesses read off `self`.
///
/// Scanned from the emitted text rather than re-derived from the graph, and that is the design decision
/// in this file. Four emitters read properties off a graph — `SeedScopeStructEmission`,
/// `ContributorProxyFacadeEmission`, `SeedlessReconstructionEmission` and `GraphConformanceEmission` —
/// and each prunes its own read set differently (per routed root, per reachable borrow, per conformance
/// member). Re-deriving that union here would mean four copies of logic that already exists, kept in
/// step by hand forever.
///
/// The asymmetry is what makes scanning the right call rather than a shortcut: **over-retention is safe
/// and under-retention breaks the build.** A property kept that nothing reads costs one stored field; a
/// property dropped that something reads is a compile error in generated code. A textual scan cannot
/// under-fire — every read is literally `<local>.<name>` in the text it is scanning — so its only
/// failure mode is the harmless one. `retainedPropertyNames` then ignores any name that is not a binding
/// in the graph it is deciding, so a read attributed too widely costs nothing at all.
///
/// **The local does not identify the graph, which is why the `<local>.` half is deliberately global.** A
/// variant graph's facade takes its parameter as `wireGraph _wireGraph: _BorrowFixture_bindMockWireGraph`
/// — the *name* comes from the scope's parent graph, the *type* is re-pointed to the variant
/// (`variantAppGraphReference`), so `_wireGraph.borrowStore` reads a variant graph through the default
/// graph's local. Attributing those reads per-local would silently drop the property from every variant.
/// Unioning across all graph locals and applying the union everywhere is the safe direction of the
/// asymmetry above, and a variant *is* the same wiring with doubles swapped in, so the union is close to
/// exact rather than merely conservative.
///
/// `self.<name>` reads stay per-struct, scoped to `extension <structName>` blocks — the graph-conformance
/// witnesses. Scanned globally, `self.` would match every synthesised factory and proxy `init` in the
/// file and retain most of the graph by accident.
package func graphPropertyReads(
    in lines: [String],
    structName: String,
    graphLocals: Set<String>
) -> Set<String> {
    var reads: Set<String> = []
    var inExtension = false
    var extensionDepth = 0
    // Some emitters append a whole block as one `lines` element (a proxy facade is a joined string), so
    // flatten before scanning — the extension tracking below is per *source* line, not per element.
    for line in lines.flatMap({ $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }) {
        // `extension _WireGraph: GraphComposable {` — but not `extension _WireGraphSomethingElse`.
        if !inExtension, startsExtension(line, of: structName) {
            inExtension = true
            extensionDepth = 0
        }
        if inExtension {
            reads.formUnion(memberReads(in: line, afterBase: "self"))
            extensionDepth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if extensionDepth <= 0 { inExtension = false }
        }
        for local in graphLocals {
            reads.formUnion(memberReads(in: line, afterBase: local))
        }
    }
    return reads
}

/// Whether `line` opens an `extension <structName>` — its conformance clause, generic clause or brace
/// following the name, so `_WireGraphSomethingElse` does not match `_WireGraph`.
private func startsExtension(_ line: String, of structName: String) -> Bool {
    guard let rest = line.strippingPrefix("extension \(structName)") else { return false }
    return rest.first.map { $0 == ":" || $0 == " " || $0 == "<" } ?? false
}

/// The member names read off `base` in one line: every `<base>.<identifier>` whose `<base>` is not itself
/// the tail of a longer identifier (so `_wireGraph` does not match inside `_myWireGraph`).
private func memberReads(in line: String, afterBase base: String) -> Set<String> {
    var reads: Set<String> = []
    let characters = Array(line)
    let baseCharacters = Array(base + ".")
    var index = 0
    while index + baseCharacters.count <= characters.count {
        defer { index += 1 }
        guard Array(characters[index..<(index + baseCharacters.count)]) == baseCharacters else { continue }
        // The character before the base must not continue an identifier.
        if index > 0, isIdentifierCharacter(characters[index - 1]) { continue }
        var end = index + baseCharacters.count
        while end < characters.count, isIdentifierCharacter(characters[end]) { end += 1 }
        let name = String(characters[(index + baseCharacters.count)..<end])
        if !name.isEmpty { reads.insert(name) }
    }
    return reads
}

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
}

extension String {
    /// The remainder after `prefix`, or `nil` when the string does not start with it.
    fileprivate func strippingPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

/// One graph struct's two deferred storage decisions: the stored-property block and the memberwise-init
/// call that has to match it.
///
/// Both are reserved as placeholder lines while `appendStruct` runs and filled by
/// `resolveStoragePatches` once the whole file exists, because what the graph stores depends on what the
/// *rest* of the file reads off it — seed-scope façades, proxy facades and conformance witnesses are all
/// emitted after the struct they read from.
package struct GraphStoragePatch {
    package let structName: String
    package let parentLocal: String
    package let topologicalOrder: [DiscoveredBinding]
    package let roots: Set<BindingIdentity>
    package let liftedParameterForIdentity: [String: String]
    package let hasTeardown: Bool
    /// M7c.2 — the bootstrap's builder local when this graph took the scheduled form, so the memberwise
    /// init takes each stored binding out of its cell (`building._wireState_pool.take()`) instead of
    /// naming a `let` local the scheduled body never bound. `nil` for the linear chain.
    package let builderLocal: String?
    package let propertyBlockIndex: Int
    package let returnLineIndex: Int
}

/// The reserved-slot marker. Distinctive enough that it cannot collide with emitted Swift, and swept out
/// of the output by `resolveStoragePatches` whether or not a patch claimed it.
package let storagePlaceholder = "\u{0}__wire_storage_slot__"

/// Fill every reserved storage slot, then sweep the unclaimed ones.
///
/// This is where M7c.1's narrowing actually happens. For each graph: scan the emitted file for what reads
/// off it, union that with the roots, `@Teardown` and opaque bindings, then emit a stored property for
/// each retained binding and an **unavailable computed stub** for each dropped one.
///
/// The stub is the migration diagnostic, and its form is a deliberate departure from M7b.3's. A build
/// warning per dropped property would never quiesce: dropping the property is the *normal* case for every
/// non-root binding, so a well-formed app would carry one warning per binding forever — the opposite of
/// M7b.3, whose pruned set is empty once an app is migrated. `@available(*, unavailable, message:)` moves
/// the same information to the only place it is actionable: the compiler reports it **at the user's own
/// `graph.x` read site**, with Wire's message and the annotation to add, and says nothing at all to an app
/// that does not read the property. It stores nothing, so it costs retention nothing — a computed property
/// is absent from the memberwise init and from `Sendable` derivation alike.
package func resolveStoragePatches(_ patches: [GraphStoragePatch], in lines: inout [String]) {
    let graphLocals = Set(patches.map(\.parentLocal))
    for patch in patches {
        let retained = retainedPropertyNames(
            in: patch.topologicalOrder,
            roots: patch.roots,
            readOffGraph: graphPropertyReads(
                in: lines,
                structName: patch.structName,
                graphLocals: graphLocals
            )
        )

        var properties: [String] = []
        var storedNames: [String] = []
        for binding in patch.topologicalOrder {
            let property = propertyName(for: binding)
            let type = wireGraphFieldType(
                for: binding,
                liftedParameterForIdentity: patch.liftedParameterForIdentity
            )
            if retained.contains(property) {
                properties.append("    let \(property): \(type)")
                storedNames.append(property)
            } else {
                // One line, attribute and all, so the stub is line-for-line what the stored property was:
                // narrowing retention must not cost generated volume, which is the axis M7b optimised.
                properties.append(
                    "    @available(*, unavailable, message: \(unretainedMessage(for: binding, property: property))) "
                        + "internal var \(property): \(type) { fatalError() }"
                )
            }
        }
        lines[patch.propertyBlockIndex] =
            properties.isEmpty ? storagePlaceholder : properties.joined(separator: "\n")

        var returnArgs =
            storedNames
            .map { name in
                guard let builder = patch.builderLocal else { return "\(name): \(name)" }
                return "\(name): \(builder)._wireState_\(name).take()"
            }
            .joined(separator: ", ")
        if patch.hasTeardown {
            returnArgs += returnArgs.isEmpty ? "_wireTeardown: _wireTeardown" : ", _wireTeardown: _wireTeardown"
        }
        lines[patch.returnLineIndex] = "    return \(patch.structName)(\(returnArgs))"
    }
    lines.removeAll { $0 == storagePlaceholder }
}

/// The `@available` message for a binding the graph builds but does not store — what the developer sees
/// at their own `graph.<property>` read site.
///
/// Names the source location as well as the annotation because the read site and the declaration are in
/// different files, and the developer is standing at the read site when they see it.
///
/// Phrased as a statement about what the graph *is*, not about what changed. A developer meeting this is
/// asking "why can't I read this?", and the answer they need is the graph's shape plus the annotation that
/// changes it. Wording it as a loss ("no longer stored") reads as a regression report, and answers a
/// question about release history that the developer at the read site did not ask.
private func unretainedMessage(for binding: DiscoveredBinding, property: String) -> String {
    let location = binding.location
    return "\"'\(property)' is constructed by the graph but not a direct property of it. "
        + "To read it as 'graph.\(property)', mark its binding at "
        + "\(location.file):\(location.line) 'allowUnused: true'.\""
}

/// A binding list keyed by identity — the shape `declaredRoots` reads. A graph's topological order
/// already holds each identity exactly once, so the collision policy never fires.
package func bindingsByIdentity(_ bindings: [DiscoveredBinding]) -> [BindingIdentity: DiscoveredBinding] {
    Dictionary(bindings.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
}
