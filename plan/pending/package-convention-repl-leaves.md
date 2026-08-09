# One leaf package per repository — the inet-julia half

The convention, the measurements behind it and the rules live in
projectured-julia: `plan/pending/package-convention-repl-leaves.md`. This file
carries only what has to happen in this repository.

The short form: a package image is built with exactly its own dependencies
present, so compiled code is safe only in a package nothing depends on and
nothing loads after. That package is the one the alias loads. Everything else
gets its compiled code voided when the session loads the rest of the stack —
measured at 3.5 s of `recompile_time` on one click in omnetpp-julia.

## Steps
Both gates are open.

## Result

**The domain split had broken this repository.** `InetExample` named
`ProjecturedDomainExample` at a path the split removed, so nothing here could
resolve at all. `run_example` now lives in `ProjecturedExample`, which brings
`ProjecturedLlm` with it — the root environment needed that source too.

`InetRepl` is at `package/repl`, the same shape as the other two: the body is
`precompile_workload(level)` in `InetExample`, the macro is in the leaf, and the
level is a Preference. `:minimal` redoes `ProjecturedExample`'s workload in this
image, `:demo` adds this repository's own catalog page.

Measured at `:demo`: `using InetRepl` 2.77 s, first paint of the catalog 0.162 s,
with 0.000 s of recompilation.


- [x] 1. `InetExample.precompile_workload(level::Symbol)` — `:none`, `:minimal`,
      `:demo`, `:full`. The body is the documents this repository owns: the
      packet and chunk domain, and the 10BASE-T1S link layer.
- [x] 2. New `package/repl/` (loaded by an environment under `env/`) → `InetRepl`, depending on `InetTest` and
      `ProjecturedSdl`, with the Preferences-driven level and `set_workload!`.
      No `@compile_workload` anywhere else in this repository.
- [ ] 3. The layering test: nothing depends on `InetRepl`; no `Example` is a
      dependency of a non-`Example`; each package's external dependencies match
      a written list.
- [ ] 4. The `ji` alias becomes `using Revise, InetRepl`. Revise stays first and
      stays out of the package's dependencies.
- [ ] 5. `InetQueuingExample` stops depending on `Test`. An example package does
      not need the test standard library; move what uses it into
      `InetQueuingTest`.
- [ ] 6. `documentation/packages.md`: the five kinds, the dependency table, and
      the leaf the `ji` alias loads.
- [ ] 7. Measure the first click at each level, so this repository has a
      baseline of its own.

## The dependency map this repository should hold

| package | should depend on | external |
| --- | --- | --- |
| `InetPacket` | — | — |
| `InetCommon` | OmnetppSimulator, ProjecturedKernel | — |
| `InetLinkLayer` | Packet, OmnetppSimulator, ProjecturedKernel | — |
| `InetQueuing` | Common, Packet, OmnetppSimulator, ProjecturedKernel | — |
| `InetRunner` | Packet, Queuing, OmnetppDescription, OmnetppFormat, OmnetppSimulator, OmnetppUnits | — |
| `Inet` | Common, LinkLayer, Packet, Queuing, OmnetppSimulator, ProjecturedVisual | — |
| `<Stem>Example` | `<Stem>`, the Examples below it | — |
| `<Stem>Test` | `<Stem>Example`, the Tests below it | — |
| `InetRepl` **(leaf)** | InetTest, ProjecturedSdl | PrecompileTools, Preferences |

No package in this repository holds a third-party dependency today, and none
should acquire one without being named in the table above.

## Depends on

`OmnetppExample.precompile_workload` and `ProjecturedExample.precompile_workload`
must exist first: `InetRepl`'s levels call through both, and this repository's
`[sources]` reach the **main** checkouts of the other two, so their halves have
to be on `main` before this one can be tested.
