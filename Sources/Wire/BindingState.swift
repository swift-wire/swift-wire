/// Per-binding construction state — the cell the generated bootstrap builds a graph out of.
///
/// A graph that Wire schedules is not a chain of `let`s but a `~Copyable` state struct owned by the
/// bootstrap frame, carrying one of these per binding. Each binding's `add` checks that its dependencies
/// have resolved, claims its own cell, constructs, and cascades into its dependents; the memberwise init
/// then takes each stored binding back out. `Documentation/Notes/ConstructionScheduling.md` is the design.
///
/// Underscore-prefixed because it is not user API. It is `public` only because generated code lives in the
/// consumer's module and has to name it — the same reason `Introspectable` and `Teardownable` are public.
///
/// ## The three read forms are the whole API
///
/// `isResolved()` for readiness, ``value()`` for a copyable dependency, ``take()`` for a move. The obvious
/// spellings each consume something they must not, and — this is the important part — **all three pass
/// `-typecheck` and fail at `-c`**, so nothing here can be checked by rendering generated text and
/// diffing it:
///
/// - `guard case .unmarked = self` inside a `mutating`/`borrowing` method consumes `self`; use `switch`
///   inside a `borrowing func`, as `isUnmarked()` does.
/// - `case .unmarked, .pending, .consumed:` — multi-pattern case labels over a noncopyable value are "not
///   implemented"; use `default:`.
/// - `guard case .resolved(let x) = someCell` consumes the *enclosing* state struct rather than the cell,
///   and does so even when the payload is copyable; use ``value()``, ``take()`` or `isResolved()`.
///
/// ## Why `take()` does not return `sending`
///
/// It would be the natural spelling: `sending` is what lets a non-Sendable payload leave for a child task,
/// and `.consumed` looks like the proof behind it. It is not, and the compiler is right to say so.
///
/// `~Copyable` on a generic parameter is a **suppression, not a requirement** — it removes the implicit
/// `Copyable` constraint, which *widens* the admissible set, so `_WireBindingState<SomeClass>` is a legal
/// instantiation. A `sending` result is a contract the body must prove for every instantiation, and the
/// only way a value enters is ``asResolved(_:)``. Consuming a *noncopyable* value transfers the sole
/// reference, so what `take()` pulls out is provably unaliased; consuming a *copyable* one transfers only
/// a reference, and the caller may keep its own. A generic body is checked once, so it must hold in the
/// worst case — and it does not.
///
/// So `.consumed` records that the cell surrendered *its* reference, which is the same thing as *the only*
/// reference exactly when `Value` is noncopyable. Under today's language the only way to promise `sending`
/// is to monomorphise the cell per payload type; the note carries that as an upstream ask.
public enum _WireBindingState<Value: ~Copyable>: ~Copyable {
    case unmarked, pending
    case resolved(Value)
    case consumed

    /// `switch` inside a `borrowing func`, not `guard case` — the latter consumes `self`.
    public borrowing func isUnmarked() -> Bool {
        switch self {
        case .unmarked: return true
        default: return false
        }
    }

    public borrowing func isResolved() -> Bool {
        switch self {
        case .resolved: return true
        default: return false
        }
    }

    /// Claim the cell, returning whether this caller is the one that must construct it.
    ///
    /// An idempotency guard, not a concurrency primitive: several dependents can cascade into the same
    /// `add`, and only the first may construct. Nothing here is shared across tasks — only the frame
    /// draining the graph mutates a cell — so there is no `Mutex` and no CAS behind it.
    public mutating func asPending() -> Bool {
        guard isUnmarked() else { return false }
        self = .pending
        return true
    }

    public mutating func asResolved(_ value: consuming Value) { self = .resolved(value) }

    /// Move the payload out, leaving the cell `.consumed`.
    ///
    /// Traps if the binding never resolved. That is unreachable in generated code — the memberwise init
    /// runs only after the cascade has settled — and it is the single failure point that replaces the N
    /// unwraps a per-binding optional would have needed.
    public mutating func take() -> Value {
        switch consume self {
        case .resolved(let value):
            self = .consumed
            return value
        default:
            fatalError("wire: binding taken before it resolved")
        }
    }
}

extension _WireBindingState where Value: Copyable {
    /// Borrowing read for a copyable payload — how a dependency is read without disturbing the cell, so a
    /// binding with several consumers is read once per consumer.
    ///
    /// Constrained to `Copyable` because reading without consuming *is* a copy. A noncopyable payload has
    /// exactly one consumer by construction, and that consumer uses ``take()``.
    public borrowing func value() -> Value? {
        switch self {
        case .resolved(let value): return value
        default: return nil
        }
    }
}
