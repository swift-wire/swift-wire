# 10 — `@BindType` can't name a macro-generated mock directly

**Repo(s):** Swift compiler limitation (surfaces at `@BindType` + `@Smock`); worked around in the example
**State:** ✅ **Worked around** (documented limitation — not a framework bug)
**Blocks:** naming a smockable `@Smock`-generated mock *directly* as a `@BindType` argument.
**Surfaced by:** Phase C (the wire-mvc-examples mocked suite). **Phase C forced this.**

## What it is

`@BindType(TodoRepository.self, MockMockableTodoRepository.self)` fails with *"cannot find
'MockMockableTodoRepository' in scope"* + *"generic parameter 'Mock' could not be inferred"* — even though the
type **is** generated (smockable's `@Smock` peer) and **is** visible to ordinary code (a sibling test file
constructs `MockMockableTodoRepository(...)` fine).

The cause is macro-vs-macro ordering: a macro's arguments are type-checked to expand it, and at that point the
compiler hasn't incorporated *another* macro's peer output. So one macro (`@BindType`) can't name a type a
different macro (`@Smock`) generates — regardless of file. (This is the compiler analogue of
`reference_macro_output_invisible_to_peers_and_plugin`: macro output is invisible to another macro.)

## Workaround (in the example)

Introduce a **non-macro** indirection — a plain `typealias` onto the generated mock — and name *that* in
`@BindType`:

```swift
// MockableProtocols.swift (with the @Smock protocols)
typealias TodoRepositoryMock = MockMockableTodoRepository

// MockedBinds.swift
@BindType(TodoRepository.self, TodoRepositoryMock.self)   // names a normal decl, not a macro's output
```

The typealias is an ordinary declaration, resolved in normal type-checking (where the `@Smock` peer is
visible), so `@BindType` sees it. Validated: the mocked suite compiles and all four tests pass.

## Use case blocked (without the workaround)

Binding a `@BindType` slot straight to an `@Smock`/other-macro-generated mock type.

## Fix sketch

No clean framework fix — it's compiler macro-expansion ordering. Options: keep the `typealias` workaround
(cheap, local); or, if `@BindType`'s mock argument only feeds WireGen's pre-expansion scan (a name, not a
resolved type), swift-wire *could* relax the `@BindType` macro's generic `Mock` parameter so an unresolved
argument doesn't fail compiler inference — but the argument is still type-checked, so this likely can't fully
sidestep the ordering. The typealias is the pragmatic answer; document it where `@BindType` meets a mock
generator.
