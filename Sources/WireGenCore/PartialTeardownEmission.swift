// Init-failure partial teardown.
//
// The half deferred from the app-scope teardown walk ([TeardownDesign.md](../../Documentation/Notes/TeardownDesign.md) § "Init-
// failure partial teardown"): if an init throws partway through bootstrap, the `@Teardown` bindings already
// constructed have to be torn down in reverse before the bootstrap rethrows. It could not be written
// against that walk's sequential chain because "the already-constructed set" is whatever the construction shape
// makes it, and that shape was still moving.
//
// **The shape it settles against is not the one the design note predicted**, because the region split divided the body
// into a chain, a group and a chain. The note assumed one state struct held every binding, so the
// constructed set could be read off the cells. Now it is three things at once: a linear prefix of locals, a
// set of resolved cells, and a linear suffix of locals. So the constructed set is **accumulated rather than
// inspected** — each `@Teardown` binding appends its action as it is built — which is the one
// representation all three regions can write to and which survives the seam in both directions.
//
// That also answers the note's ordering worry. It expected the `do`/`catch` *inside* the group body, and
// warned that `withThrowingTaskGroup`'s own `cancelAll()`-and-drain runs after such a `catch`, so generated
// code would have to cancel and drain itself before touching a resource a sibling task might still hold.
// The accumulator puts the `catch` **outside** the group instead — it has to, because the prefix is built
// before the group opens — and by the time it runs, `withThrowingTaskGroup` has already cancelled the group
// and awaited every remaining child. The explicit `cancelAll()` is unnecessary rather than forgotten.

/// The accumulator: every `@Teardown` action for a binding that has actually been constructed, in
/// construction order. Declared before the `do` so the `catch` can still see it.
///
/// One list serves both paths. On success it becomes the graph's `_wireTeardown`; on a throw the `catch`
/// walks it in reverse and rethrows. That is deliberate — a second list for the failure path would be the
/// same teardown call lines emitted twice, kept in step by hand.
func teardownAccumulatorLines(indent: String = "    ", name: String = "_wireTeardownActions") -> [String] {
    ["\(indent)var \(name): [@Sendable () async -> [any Error]] = []"]
}

/// One binding's action, appended where it is constructed.
///
/// The closure closes over the binding's *local* — the same concrete-type capture the happy-path closure
/// has always used, which is what lets `@Teardown` work on an `@Singleton(as:)` binding whose graph
/// property is an opaque `some P`.
func teardownActionAppendLines(
    for binding: DiscoveredBinding,
    indent: String,
    accumulator: String = "_wireTeardownActions"
) -> [String] {
    guard binding.teardown != nil else { return [] }
    // `errors` is appended to only by a throwing member or a producer action. A non-throwing member never
    // touches it, and a `var` nothing mutates is a warning in the generated file.
    let mutatesErrors: Bool
    switch binding.teardown?.kind {
    case .member(_, _, let isThrowing): mutatesErrors = isThrowing
    case .action: mutatesErrors = true
    case nil: mutatesErrors = false
    }
    return [
        "\(indent)\(accumulator).append({",
        "\(indent)    \(mutatesErrors ? "var" : "let") errors: [any Error] = []",
    ]
        + teardownCallLines(for: binding, indent: "\(indent)    ")
        + [
            "\(indent)    return errors",
            "\(indent)})",
        ]
}

/// The graph's captured teardown, folded from the accumulator.
///
/// Reverse *append* order, which is reverse construction order — the same walk the static reverse
/// topological order produced before, since every region is emitted in topological order and the group's
/// cells are drained into locals in theirs.
///
/// `[_wireTeardownActions]` is a by-value capture list rather than the implicit one: the accumulator is a
/// `var`, and an escaping `@Sendable` closure cannot capture a mutable local by reference.
func accumulatedTeardownClosureLines(
    indent: String,
    local: String = "_wireTeardown",
    type: String = "@Sendable () async -> [any Error]",
    accumulator: String = "_wireTeardownActions"
) -> [String] {
    [
        "\(indent)let \(local): \(type) = { [\(accumulator)] in",
        "\(indent)    var errors: [any Error] = []",
        "\(indent)    for action in \(accumulator).reversed() {",
        "\(indent)        errors.append(contentsOf: await action())",
        "\(indent)    }",
        "\(indent)    return errors",
        "\(indent)}",
    ]
}

/// The `catch` that runs the accumulated actions and rethrows.
///
/// Teardown errors are **discarded**, and the original error is what propagates. A caller of
/// `Wire.bootstrap()` is being told why the graph could not be built; a secondary failure while unwinding
/// resources that are about to be abandoned is not the answer to that question. (Happy-path `teardown()`
/// does the opposite and returns them, because there the errors *are* the result.)
func partialTeardownCatchLines(indent: String, accumulator: String = "_wireTeardownActions") -> [String] {
    [
        "\(indent)} catch {",
        "\(indent)    for action in \(accumulator).reversed() {",
        "\(indent)        _ = await action()",
        "\(indent)    }",
        "\(indent)    throw error",
        "\(indent)}",
    ]
}

/// The group's half: on a throw during the drain, record whichever scheduled `@Teardown` bindings had
/// reached `.resolved`, then rethrow into the outer `catch`.
///
/// This is the one place the constructed set really is *inspected* rather than accumulated, because a
/// scheduled binding is built inside a method of the building struct, where the accumulator is not in
/// scope. Emitted in the group's own (topological) order and appended last, so the outer walk reverses them
/// ahead of anything the prefix contributed — dependents before dependencies, as ever.
///
/// `take()` rather than a borrow: the cells are being abandoned, and it is the only way to move a payload
/// out of one.
func groupTeardownRecoveryLines(
    tornInGroup: [DiscoveredBinding],
    indent: String,
    accumulator: String = "_wireTeardownActions"
) -> [String] {
    guard !tornInGroup.isEmpty else { return [] }
    var lines = ["\(indent)} catch {"]
    for binding in tornInGroup {
        let local = propertyName(for: binding)
        lines.append("\(indent)    if building.\(stateCellName(for: binding)).isResolved() {")
        lines.append("\(indent)        let \(local) = building.\(stateCellName(for: binding)).take()")
        lines.append(
            contentsOf: teardownActionAppendLines(
                for: binding,
                indent: "\(indent)        ",
                accumulator: accumulator
            )
        )
        lines.append("\(indent)    }")
    }
    lines.append("\(indent)    throw error")
    lines.append("\(indent)}")
    return lines
}

/// Whether the construction body can fail at all — the other half of the trigger.
///
/// Read off the emitted construction lines rather than re-derived from binding effects, for the reason
/// the retention scan gives: four places decide what carries `try`, and re-deriving the union would be
/// four copies kept in step by hand. Over-firing here is not free — a `do` block that cannot throw draws
/// `'catch' block is unreachable`, in generated code — so the scan is given the construction lines only,
/// never the teardown closure's own body, which always contains a `try` of its own.
func constructionCanThrow(_ lines: [String]) -> Bool {
    lines.contains { $0.contains("try ") }
}
