# Move the packet/chunk API and the 10BASE-T1S model into `inet-julia`

**Status:** done.
**Scope:** extract `Omnetpp.PacketModule` (the packet & chunk API) and
`Omnetpp.T1sModule` + `T1sModel` (the 10BASE-T1S/PLCA multidrop model) out of
`omnetpp-julia` and into a new `Inet` package in `inet-julia`, together with
their tests, examples, documentation and design plans.

## 1. Why

`omnetpp-julia` is the simulation kernel — the DES engine, the lifecycle, the
result recording. The packet/chunk API and the Ethernet/PLCA model are *model
library* concerns: in the C++ world they live in INET, not in OMNeT++.
Keeping them in the kernel repo inverts that layering and grows the kernel's
surface with protocol-specific vocabulary.

`plan/done/packet-chunk-api.md` §9.5 already flagged the extraction as cheap
precisely because the chunk layer has no dependency on the simulator core.

## 2. Dependency direction (decided)

```
inet-julia (Inet)  ──depends on──▶  omnetpp-julia (Omnetpp)
```

**Nothing in `omnetpp-julia` may depend on `inet-julia`.** That is the
acceptance criterion for the omnetpp-julia side: after the move its `Project.toml`
gains no dependency, and no file under `src/`, `test/`, `examples/`, `watch/`,
`benchmark/` or `scripts/` mentions `Inet`, `PacketModule`, `T1sModule` or
`T1sModel`.

Consequence: `T1sModel` must leave `default_simulation_catalog()`
(`src/lifecycle/Workbench.jl`). The catalog is deliberately a *value*, not a
registry, so `Inet` re-offers it through its own catalog helper instead.

## 3. Naming (decided)

- Package `Inet`, uuid `e0528acb-81c4-485d-8c9f-a32e8325f910`, root module `Inet`.
- Submodules keep their names: `Inet.PacketModule`, `Inet.T1sModule`.
- No compatibility re-export from `Omnetpp` — every call site is rewritten.

## 4. Inventory

Moves to `inet-julia` (deleted from `omnetpp-julia`):

| from | to |
|---|---|
| `src/packet/*.jl` (13 files, 1639 lines) | `src/packet/` |
| `src/t1s/*.jl` (9 files, 2110 lines) | `src/t1s/` |
| `src/model/T1sModel.jl` | `src/model/T1sModel.jl` |
| `test/packet/*.jl` (7 files) | `test/packet/` |
| `test/t1s/*.jl` (16 files) + `test/t1s/inet-reference/notraffic.vec` | `test/t1s/` |
| `examples/packet_api_demo.jl` | `examples/` |
| `scripts/compare_t1s_vectors.jl` | `scripts/` |
| `documentation/packet.md`, `documentation/ten-base-t1s.md` | `documentation/` |
| `plan/done/packet-chunk-api.md`, `plan/done/ten-base-t1s-plca.md`, `plan/done/ten-base-t1s-statistics.md` | `plan/done/` |

Edited in place in `omnetpp-julia`:

- `src/Omnetpp.jl` — drop the `packet/Packet.jl`, `t1s/T1s.jl`,
  `model/T1sModel.jl` includes and the `T1sModel, AbstractT1sModel, T1sModelMut`
  exports.
- `src/lifecycle/Workbench.jl` — drop `SimulationType(T1sModel)` from
  `default_simulation_catalog()`.
- `test/runtests.jl` — drop the packet and T1S testsets.
- `README.md` — drop the `src/packet/`, `src/t1s/` structure entries if present.

Stays in `omnetpp-julia` (not t1s-specific): `test/GOLDEN.md`,
`test/golden_hashes.jl`, `results/`.

## 5. What `Inet` needs from `Omnetpp`

`PacketModule` needs nothing (standalone, `import Base: peek` only).
`T1sModule` and `T1sModel` need, from `Omnetpp`:

- values/types: `SimTime`, `TIME_UNIT`, `to_simtime`, `MersenneTwister`,
  `EventContext`, `SimulationEngine`, `AbstractModel`, `AbstractParallelEngine`,
  `SimTimeLimit`, `Parameter`, `ParameterSpace`, `AbstractResolvedParameters`,
  `StructuralDOF`, `StochasticDOF`, `IterationDOF`, `Recorder`,
  `VectorFileWriter`, `begin_recording!`, `schedule!`, `schedule_root!`,
  `stop!`, `register_indexed_vector!`, `emit_indexed_vector!`, `record_scalar!`,
  `SimulationType`, `default_simulation_catalog`.
- functions `Inet` must **extend** (so `import`, not `using`):
  `model_module_count`, `model_barrier_module`, `model_delay_edges`,
  `model_description`, `model_parameter_space`, `build_model`, `reset_model!`,
  `schedule_initial_events!`, `make_recorder`.

Plus `@document` from `ProjecturedKernel.DocumentModule`.

## 6. Steps

- [x] **S0** — plan; sibling worktree `omnetpp-julia-inet` on branch
  `move-packet-t1s-to-inet-julia` for the omnetpp-julia side.
- [x] **S1** — `inet-julia` skeleton: `Project.toml` (`Inet`, deps `Omnetpp` +
  `ProjecturedKernel`, `[sources]` to the sibling checkouts), `.gitignore`,
  `src/Inet.jl`.
- [x] **S2** — move `src/packet/` + `test/packet/` + `examples/packet_api_demo.jl`
  + `documentation/packet.md` + `plan/done/packet-chunk-api.md`; rewrite
  `Omnetpp.PacketModule` → `Inet.PacketModule` at every call site. Packet tests
  green (needs no `Omnetpp`).
- [x] **S3** — move `src/t1s/`, `src/model/T1sModel.jl`, `test/t1s/`,
  `scripts/compare_t1s_vectors.jl`, `documentation/ten-base-t1s.md` and the two
  T1S plans; wire the `Omnetpp` imports listed in §5; add
  `inet_simulation_catalog()`. Full `inet-julia` suite green.
- [x] **S4** — omnetpp-julia removal in the worktree: delete the moved files,
  strip `src/Omnetpp.jl`, `src/lifecycle/Workbench.jl`, `test/runtests.jl`.
  Remaining suite green; grep proves no `Inet`/`Packet`/`T1s` reference
  survives. `README.md` needed no edit — it never named the moved subtrees.
- [x] **S5** — `inet-julia` README, then land: merge the worktree branch into
  `omnetpp-julia` master (ff-only) and verify the full `inet-julia` suite
  against the merged checkout. `omnetpp-julia` pushed; `inet-julia` is committed
  locally but **not pushed** — `levy/inet-julia` is readable yet rejects writes
  from both the `omnetpp-julia` deploy key and the `projectured` account, so it
  needs its own deploy key (or push rights) before `git push -u origin main`
  will go through.

## 7. Testing

- Packet half: `julia --project=. test/runtests.jl` in `inet-julia` — no
  `Omnetpp` involvement, so it runs from S2 on.
- T1S half needs an `Omnetpp` *without* `T1sModel` (otherwise the name is
  exported by both packages and the test files clash). Until S5 lands, run
  against the worktree through a scratchpad environment whose `[sources]` point
  `Omnetpp` at `omnetpp-julia-inet`; after S5 the repo's own `[sources]`
  (`../omnetpp-julia`) are correct.
- omnetpp-julia half: `julia --project=. test/runtests.jl` in the worktree.

## 8. Decisions made during implementation

- **`Inet` re-exports nothing from `Omnetpp`.** Scripts that need both say
  `using Omnetpp, Inet`. A re-export would make `Inet` look like a superset of
  the kernel and hide which layer a name comes from.
- **`ProjecturedBase` is not named in `[sources]`.** Pkg refuses a `[sources]`
  entry for a package absent from `[deps]`/`[extras]`, and it turned out not to
  be needed: Julia 1.12 resolves `Omnetpp`'s *own* `[sources]` transitively, so
  `ProjecturedBase` is found through the `Omnetpp` path dependency.
- **`examples/` was not given its own environment.** `inet-julia`'s one example
  (`packet_api_demo.jl`) needs only `Inet`, so it runs under the root project;
  no `examples/Project.toml` is carried over.
- **Done plans move verbatim.** `plan/done/*.md` are historical records of how
  the code came to be; their `omnetpp-julia`-era paths and module names are left
  untouched. Only the live documentation under `documentation/` is rewritten to
  describe where the code is now.
- **`@document` needs more than the macro imported.** The expansion of
  `@document struct T1sModel` references `Reference` and the cell primitives by
  name, so `Inet.jl` imports `Document`, `sync_document!`, `Reference`,
  `ImmutableCell` and `set_cell_function!` alongside the macro — the same set
  `Omnetpp.jl` imports. Importing only `@document` fails at precompile with
  `UndefVarError: Reference not defined in Inet`.
- **`T1sModule` now imports `Omnetpp` absolutely.** Inside `Omnetpp` it said
  `using ..Omnetpp: …`; as a submodule of `Inet` that relative path would resolve
  to `Main`, so it is `using Omnetpp: …` (a package dependency). The sibling
  `using ..PacketModule` is unchanged — `PacketModule` is still a sibling.
- **`Pkg.test()` was already broken in `omnetpp-julia`** — `test/runtests.jl`
  opens `using Statistics` with no such test dependency declared, so the
  documented command died before running anything. Fixed in its own commit on
  the worktree branch, since the removal cannot otherwise be verified.
- **Cross-repo testing before the merge.** Until the removal lands on
  `omnetpp-julia` master, both packages export `T1sModel` and the test files
  clash. The full `inet-julia` suite was therefore run from a throwaway
  environment whose `[sources]` point `Omnetpp` at the worktree.

## 9. Result

Behaviour-preserving: the moved suites report exactly the counts they did inside
`omnetpp-julia` — 1680 packet checks and 414 T1S checks — and `T1sModel`'s
pinned golden hash (`0x429fe1b7ab8d705cbaaa4926d57e103b`) reproduces through the
lifecycle from the new package. `omnetpp-julia`'s remaining suite is green under
`-t 8` (the parallel-engine stage assertions need more than one thread).
