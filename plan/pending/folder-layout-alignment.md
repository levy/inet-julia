# Folder layout alignment

Status: pending (design accepted-for-review, 2026-08-04)

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

- **Sequencing rule:** the `queuing-tutorial` branch edits `InetQueuing.jl`'s
  include list and adds two files into exactly the folders this plan
  reorganizes (`common/PacketPredicates.jl`, `common/PacketMarking.jl`). Land
  that branch **before** executing M1–M2, or the moves and the branch conflict
  file-for-file. This plan's §3 already accounts for both incoming files.
- Each executed move updates the file's path in [SEALING.md](../../SEALING.md)
  **in place** — the entry keeps its position (the rules forbid reordering,
  not renaming a path).
- Execute before wave A4–A5 so those waves audit the final paths.

## 3. The moves — `InetQueuing` (`package/queuing/main/`)

Each is one commit: `git mv` + the include-path edit in `InetQueuing.jl` +
the SEALING.md path update + a grep for stale citations (`documentation/`,
`package/*/doc/`, `plan/`, the tutorial content) + `test_queuing()` green.

- [ ] **M1 — retire the `common/` grab-bag.** Today `common/` holds
  `PacketPlumbing.jl` (layer 4, composition), and the tutorial branch adds
  `PacketPredicates.jl` (layer 2, base — the questions elements ask about a
  packet) and `PacketMarking.jl` (layer 4 — labelling, cloning, duplicating)
  beside it. One folder, two layers, and a name that says nothing. Split by
  layer:
  - `common/PacketPredicates.jl` → `base/PacketPredicates.jl`
  - `common/PacketPlumbing.jl` → `compound/PacketPlumbing.jl`
  - `common/PacketMarking.jl` → `compound/PacketMarking.jl`
  (If `queuing-tutorial` has not landed, M1 moves only `PacketPlumbing.jl` and
  the branch's two files are placed directly into their final folders when it
  merges — cheaper than moving them twice.)
- [ ] **M2 — `queue/PriorityQueue.jl` → `compound/PriorityQueue.jl`.** It is
  the package's first compound module — built by composition, owning
  submodules and doing nothing itself, as its own docstring says — and loads
  in the composition layer, not with the leaf elements. Leaving it in
  `queue/` reads as "a kind of queue element", which is the one thing it is
  not.

After M1–M2 the element folders (`source/`, `sink/`, `queue/`, `server/`,
`classifier/`, `scheduler/`, `filter/`) hold exactly the layer-3 leaf
elements, and `compound/` holds the layer-4 built-from-others ones — the
folder set then reads as the layer map.

## 4. Decisions to record, not moves (default: leave)

- [ ] **D1 — `packet` stays flat.** `InetPacket` is one module with 12 files
  in a dependency-ordered flat list (bit lengths → quality → chunks → peek →
  IO → headers → tags → envelope → buffers → inspection). It is a single
  slice; subfoldering it would invent a boundary the module does not enforce.
  **Default: leave.**
- [ ] **D2 — `linklayer` keeps `t1s/` flat.** Ten files in one protocol slice,
  including the two generated FSM files beside the hand-written halves they
  belong to (`Mac.jl`/`MacFsm.jl`, `PlcaControl.jl`/`PlcaFsm.jl`) — that
  adjacency is the point, and a `generated/` subfolder would separate a pair
  that must be read together. **Default: leave.** When a second protocol
  arrives it is a sibling slice folder (`ethernet/`, …), never a package.
- [ ] **D3 — `T1sModel.jl` and `T1sCapture.jl` stay at package root, not in
  `t1s/`.** Both are included by `InetLinkLayer.jl` directly rather than by
  `t1s/T1s.jl`, which is honest: the model wrapper is the slice's face to the
  simulation lifecycle and the capture file is its face to the observation
  machinery — both sit outside `T1sModule`. Their paths (`t1s/T1sModel.jl`,
  `t1s/T1sCapture.jl`) already place them in the slice folder while the
  include structure keeps them outside the inner module. **Default: leave**;
  record the reason so the next reader does not "tidy" them into `T1s.jl`.
- [ ] **D4 — no `main/src/` level here.** `inet-julia` puts sources directly
  under `main/` while `omnetpp-julia` nests them under `main/src/`. This repo
  matches `projectured-julia`; the divergence is the sibling's to record (its
  own plan's D2). **Default: leave, and do not "align" toward the sibling.**

## 5. Verification

- After each move: `julia --project=package/queuing/test -e 'using
  InetQueuingTest; test_queuing()'`.
- After M1–M2 as a group: `julia --project=. test/runtests.jl` once, plus a
  repo-wide grep for the old paths (`common/PacketPlumbing`,
  `queue/PriorityQueue`, and the two incoming `common/Packet*` paths) over
  `documentation/`, `package/*/doc/`, `plan/` and `SEALING.md` — zero stale
  references. The linklayer golden hashes are untouched by these moves but the
  full run confirms it.

## 6. Not in this plan

- Anything in `packet`, `common`, `linklayer`, `inet` (nothing to align).
- The `InetQueuingExample` package's internal layout — it arrives with
  `queuing-tutorial` and is reviewed in Wave D, together with the
  `TutorialShell` promotion the `demo-catalog` plan expects.
- Renaming modules or splitting files — the audit waves own per-file findings.

The sibling plan in omnetpp-julia:
`../omnetpp-julia/plan/pending/folder-layout-alignment.md`.
