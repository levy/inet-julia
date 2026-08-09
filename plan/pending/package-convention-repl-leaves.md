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

- [ ] 1. `InetExample.precompile_workload(level::Symbol)` — `:none`, `:minimal`,
      `:demo`, `:full`. The body is the documents this repository owns: the
      packet and chunk domain, and the 10BASE-T1S link layer.
- [ ] 2. New `package/repl/` → `InetRepl`, depending on `InetTest` and
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
