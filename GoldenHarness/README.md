# Golden harness — the generated-output gate

One question: **did generated output change?**

```bash
bash GoldenHarness/run-golden-harness.sh           # compare (CI runs this)
bash GoldenHarness/run-golden-harness.sh --update  # re-record after an intended change
```

It runs the real `WireGen` over `Tests/IntegrationTests` — ~70 example files covering containers, seed
scopes, contributor proxies, graph conformances, teardown, member injection, opaque lifts and testing
variants — plus its Wire-aware sibling `WireTestLibrary`, which is exactly the pair of module groups
`WireBuildPlugin` passes for that target. The output is diffed against `Golden/`.

**A diff is not automatically a failure — it is an *unreviewed* change.** Read it, decide whether it is
what you meant, then re-record with `--update` and commit the recording in the same change that caused it.

## Why it exists

Two milestones are written against the same invariant, and neither can be trusted without this:

- **M7b — reachability pruning.** "A graph in which every binding is already reachable from a root
  produces byte-identical generated output before and after M7b." That is what makes pruning invisible to
  single-module apps.
- **M8 — noncopyable bindings.** "A graph containing no `~Copyable` or `~Escapable` bindings produces
  byte-identical generated output."

## Notes

- **Outside `swift test`**, because the guard is over WireGen's *output files* and WireGen is an
  executable target a test target cannot import.
- **Recorded as `.swift.golden`, not `.swift`.** The format job runs `swift-format format --recursive
  --in-place .` and fails on any resulting diff, so a committed *generated* Swift file would be
  reformatted under it and break the build.
- **Determinism** comes from lexicographic globs for the file lists; two runs on one checkout are
  byte-identical.
- **Machine-independence** comes from generating with paths relative to the repository root. WireGen echoes
  the path it was handed into `#sourceLocation(file:)` and into `introspect()`'s `SourceLocation`, so an
  absolute path would bake the recording machine's checkout location into the golden — which is exactly
  how the first version of this harness passed locally and failed in CI. The script asserts the generated
  output contains no absolute path, so the property is enforced rather than remembered.
