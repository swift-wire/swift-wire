import Testing

@testable import Wire

/// The construction cell's behaviour (construction scheduling).
///
/// These exist because the cell's characteristic failure modes **pass `-typecheck` and fail at `-c`** —
/// the three consuming spellings its API is shaped to avoid. Assertions over rendered generated text
/// cannot catch any of them, so the semantics are pinned here, where they compile and run.
@Suite("Binding state")
struct BindingStateTests {
    @Test func aFreshCellIsUnmarkedAndNotResolved() {
        let cell = _WireBindingState<Int>.unmarked
        let unmarked = cell.isUnmarked()
        let resolved = cell.isResolved()
        #expect(unmarked)
        #expect(!resolved)
    }

    @Test func onlyTheFirstClaimantConstructs() {
        // The idempotency guard the cascade depends on: several dependents can reach the same `add`, and
        // exactly one may construct. Not a concurrency primitive — only one frame ever mutates a cell.
        var cell = _WireBindingState<Int>.unmarked
        let first = cell.asPending()
        let second = cell.asPending()
        #expect(first)
        #expect(!second)
    }

    @Test func aResolvedCellCannotBeClaimedAgain() {
        var cell = _WireBindingState<Int>.unmarked
        _ = cell.asPending()
        cell.asResolved(7)
        let resolved = cell.isResolved()
        let reclaimed = cell.asPending()
        #expect(resolved)
        #expect(!reclaimed)
    }

    @Test func valueReadsWithoutDisturbingTheCell() {
        // The load-bearing property for a multi-consumer binding: reading a dependency must leave the cell
        // resolved so the next consumer can read it too. `guard case .resolved(let x) = cell` would
        // consume the enclosing state struct instead, which is the spelling this method exists to avoid.
        var cell = _WireBindingState<Int>.unmarked
        cell.asResolved(7)
        let first = cell.value()
        let second = cell.value()
        let stillResolved = cell.isResolved()
        #expect(first == 7)
        #expect(second == 7)
        #expect(stillResolved)
    }

    @Test func valueIsNilBeforeResolution() {
        let unmarked = _WireBindingState<Int>.unmarked
        let unmarkedValue = unmarked.value()
        #expect(unmarkedValue == nil)
        var pending = _WireBindingState<Int>.unmarked
        _ = pending.asPending()
        let pendingValue = pending.value()
        #expect(pendingValue == nil)
    }

    @Test func takeMovesThePayloadOutAndConsumesTheCell() {
        var cell = _WireBindingState<Int>.unmarked
        cell.asResolved(7)
        let taken = cell.take()
        let resolvedAfter = cell.isResolved()
        let unmarkedAfter = cell.isUnmarked()
        #expect(taken == 7)
        #expect(!resolvedAfter)
        #expect(!unmarkedAfter)
    }

    @Test func takeHandsBackTheSameReferenceRatherThanACopy() {
        // What makes a graph's stored property and its consumers one object.
        final class Box { var n = 0 }
        let box = Box()
        var cell = _WireBindingState<Box>.unmarked
        cell.asResolved(box)
        let taken = cell.take()
        #expect(taken === box)
    }

    @Test func aCellCarriesANoncopyablePayload() {
        // The reason the cell is generic over `~Copyable` at all: noncopyable bindings's noncopyable bindings need no second
        // emitter, because storing and moving one is the same structure. `value()` is deliberately absent
        // here — reading without consuming is a copy — so `take()` is the only way out, which is also the
        // rule for a noncopyable binding's single consumer.
        struct Token: ~Copyable { let secret: String }
        var cell = _WireBindingState<Token>.unmarked
        let claimed = cell.asPending()
        cell.asResolved(Token(secret: "s"))
        let resolved = cell.isResolved()
        let token = cell.take()
        let resolvedAfter = cell.isResolved()
        #expect(claimed)
        #expect(resolved)
        #expect(token.secret == "s")
        #expect(!resolvedAfter)
    }
}
