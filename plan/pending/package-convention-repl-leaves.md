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
- [ ] 3. The layering test: nothing depends on `InetRepl`.
- [ ] 4. The `ji` alias becomes `using Revise, InetRepl`. Revise stays first and
      stays out of the package's dependencies.
- [ ] 5. Measure the first click at each level, so this repository has a
      baseline of its own.

## Depends on

`OmnetppExample.precompile_workload` and `ProjecturedExample.precompile_workload`
must exist first: `InetRepl`'s levels call through both, and this repository's
`[sources]` reach the **main** checkouts of the other two, so their halves have
to be on `main` before this one can be tested.
