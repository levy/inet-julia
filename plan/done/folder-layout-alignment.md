# Folder layout alignment

Status: **done** (design 2026-08-04, executed 2026-08-12). M1 and M2 landed,
and D1–D4 are recorded below. The layer-4 folder is named `composition/`, not
`compound/` — see M1 for the reason the code gave.

## 1. Goal

Make the folder layout tell the same story as the layer map, where it
currently contradicts it. Unlike the sibling repo, `inet-julia` has almost
nothing to fix: `packet`, `common`, `linklayer` and `inet` already match, and
only `queuing`'s `common/` folder — a grab-bag that spans two layers — and one
misfiled compound element are genuinely misleading.

Folders are a readability boundary; the architecture is enforced by dependency
direction and the include order in each package root. These moves change paths
only: no include *order* change, no module change, no behaviour change. Golden
hashes must come out unchanged.

## 2. Relation to the audit campaign

Satellite of [architecture-audit-and-seal.md](architecture-audit-and-seal.md):

- **Sequencing rule — cleared.** The `queuing-tutorial` branch landed, and so
  did `queuing-elements-on-the-module-macro`, which rewrote every element onto
  `@simulation_module`. Both files this plan waited for
  (`common/PacketPredicates.jl`, `common/PacketMarking.jl`) were in place when
  M1 ran, so each moved once.
- Each executed move updates the file's path in [SEALING.md](../../SEALING.md)
  **in place** — the entry keeps its position (the rules forbid reordering,
  not renaming a path).
- Execute before wave A4–A5 so those waves audit the final paths.

## 3. The moves — `InetQueuing` (`package/queuing/main/`)

Each is one commit: `git mv` + the include-path edit in `InetQueuing.jl` +
the SEALING.md path update + a grep for stale citations (`documentation/`,
`package/*/doc/`, `plan/`, the tutorial content) + `test_queuing()` green.

- [x] **M1 — retire the `common/` grab-bag.** `common/` held
  `PacketPlumbing.jl` (layer 4), `PacketPredicates.jl` (layer 2, base — the
  questions elements ask about a packet) and `PacketMarking.jl` (layer 4 —
  labelling, cloning, duplicating). One folder, two layers, and a name that
  said nothing. Split by layer:
  - `common/PacketPredicates.jl` → `base/PacketPredicates.jl`
  - `common/PacketPlumbing.jl` → `composition/PacketPlumbing.jl`
  - `common/PacketMarking.jl` → `composition/PacketMarking.jl`

  **The folder is `composition/`, not `compound/`.** The plan said `compound/`,
  and the code that landed since made that name false. `PacketPlumbing.jl` and
  `PacketMarking.jl` declare six `@simulation_module` elements — a multiplexer,
  a demultiplexer, a delayer, a labeler, a cloner and a duplicator — and not one
  of them owns a submodule. Only `PriorityQueueModule` is an
  `AbstractCompoundModule`. A folder called `compound/` holding three files of
  which one is compound is the same lie as `common/`, told the other way round.
  `composition` is what the layer is called in
  [architecture-audit-and-seal.md](architecture-audit-and-seal.md) §3 and in
  [SEALING.md](../../SEALING.md), which already names the group
  **Layer 4 — composition**. The folder now says what the layer says.
- [x] **M2 — `queue/PriorityQueue.jl` → `composition/PriorityQueue.jl`.** It is
  the package's only compound module — built by composition, owning
  submodules and doing nothing itself, as its own docstring says — and loads
  in the composition layer, not with the leaf elements. Leaving it in
  `queue/` reads as "a kind of queue element", which is the one thing it is
  not.

After M1–M2 the element folders (`source/`, `sink/`, `queue/`, `server/`,
`classifier/`, `scheduler/`, `filter/`) hold exactly the layer-3 leaf
elements, and `composition/` holds the layer-4 ones — the elements that join
other elements, and the one compound built out of them. The folder set reads as
the layer map.

The include list keeps its order. The three composition includes moved to the
end of the element block, under a comment that names the layer, which is where
they already were.

## 4. Decisions to record, not moves (default: leave)

- [x] **D1 — `packet` keeps one flat level, plus `protocol/`.** `InetPacket` is
  one module whose 23 root files are a dependency-ordered flat list (bit
  lengths → quality → chunks → peek → IO → headers → tags → envelope → buffers
  → inspection → header facts). It is a single slice, and subfoldering that
  list would invent a boundary the module does not enforce. The one subfolder
  it has, `protocol/`, is not a layer: it is 38 files of declared wire formats,
  one per protocol family, and it grew from 19 files to 38 while
  `protocol-header-inventory.md` ran. That folder earns its place by size and
  by having one honest membership rule. **Decided: leave both.**
- [x] **D2 — `linklayer` keeps `t1s/` flat.** Twelve files in one protocol slice,
  including the two generated FSM files beside the hand-written halves they
  belong to (`Mac.jl`/`MacFsm.jl`, `PlcaControl.jl`/`PlcaFsm.jl`) — that
  adjacency is the point, and a `generated/` subfolder would separate a pair
  that must be read together. **Decided: leave.** When a second protocol
  arrives it is a sibling slice folder (`ethernet/`, …), never a package.
- [x] **D3 — `T1sModel.jl` and `T1sCapture.jl` stay outside `T1s.jl`.** Both are included by `InetLinkLayer.jl` directly rather than by
  `t1s/T1s.jl`, which is honest: the model wrapper is the slice's face to the
  simulation lifecycle and the capture file is its face to the observation
  machinery — both sit outside `T1sModule`. Their paths (`t1s/T1sModel.jl`,
  `t1s/T1sCapture.jl`) already place them in the slice folder while the
  include structure keeps them outside the inner module. **Decided: leave**;
  the reason is recorded here so the next reader does not "tidy" them into
  `T1s.jl`.
- [x] **D4 — no `main/src/` level here.** `inet-julia` puts sources directly
  under `main/` while `omnetpp-julia` nests them under `main/src/`. This repo
  matches `projectured-julia`; the divergence is the sibling's to record (its
  own plan's D2). **Decided: leave, and do not "align" toward the sibling.**

## 5. Verification — done

- [x] The repo-wide grep for the old paths (`common/PacketPredicates`,
      `common/PacketPlumbing`, `common/PacketMarking`, `queue/PriorityQueue`)
      over `documentation/`, `package/*/doc/`, `plan/` and `SEALING.md`. Only
      `SEALING.md` and this plan cited them, and both now carry the new paths.
      No source file outside `InetQueuing.jl` names a moved file by path.
- [x] `test_queuing()`, run from the repository root environment, which is the
      environment a test package resolves in:

      julia --project=. -e 'using InetQueuingTest; test_queuing()'

      469 pass, 1 fail, 2 errors. The same commit measured at its parent gives
      281 pass, 1 fail, 2 errors — so the moves add no failure, and the extra
      188 passes are the tutorial check that step 5 of
      [package-convention-repl-leaves.md](package-convention-repl-leaves.md)
      wired into the suite.

**The one failure and the two errors are pre-existing and are not this plan's.**
They reproduce exactly at the parent commit:

- `phase1_sources_sinks.jl:213`, "a run is reproducible" — one failed
  assertion.
- `phase5_capture.jl:25` and `:88` — `FieldError: type
  OmnetppSimulator.Capture has no field 'buffer', available fields: 'spec',
  'points', 'buffers', 'dropped', 'capacity', 'active'`. That is upstream
  drift: `omnetpp-julia` renamed the field and this repository's capture tests
  still read the old name. It is a finding against
  [architecture-audit-and-seal.md](architecture-audit-and-seal.md) wave C, not
  against the layout.

## 6. Not in this plan

- Anything in `packet`, `common`, `linklayer`, `inet` (nothing to align).
- The `InetQueuingExample` package's internal layout — it arrives with
  `queuing-tutorial` and is reviewed in Wave D, together with the
  `TutorialShell` promotion the `demo-catalog` plan expects.
- Renaming modules or splitting files — the audit waves own per-file findings.

The sibling plan in omnetpp-julia is done:
`../omnetpp-julia/plan/done/folder-layout-alignment.md`.
