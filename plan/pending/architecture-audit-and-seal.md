# Architecture audit and seal

Status: pending. Written 2026-08-04; **refreshed 2026-08-10** against ~165
commits of change.

## 1. Goal

Audit every file in `inet-julia` against the architecture requirements, fix
what the audit finds, and seal file by file — linearly, in dependency order.
The sealing state and rules live in [SEALING.md](../../SEALING.md); this plan
is the campaign that walks it. The sibling campaign in `omnetpp-julia`
(`plan/pending/architecture-audit-and-seal.md` there) runs the same protocol on
the substrate, where the audit order is now that repository's
`simulation-anatomy.md` ladder. This repository has no anatomy of its own: its
ladder is the package graph and the layers inside each package.

## 2. What exists, what is missing

| artifact | state |
| --- | --- |
| `documentation/architecture.md` | current — the seven packages, what each owns, the placement rule, environments, testing |
| `documentation/packages.md` | new — the five package kinds and the one dependency direction, the same shape in all three repositories |
| `documentation/requirements.md` | `IR-…`, 12 requirements — **still not formally reviewed**, though later plans already cite them |
| `documentation/architecture-requirements.md` | `IAR-…`, 16 rules — same state; `IAR-FOUR-STRUCT-ELEMENT` was dropped 2026-08-12, see P0.2 |
| `SEALING.md` | authoritative; inventory re-synced 2026-08-10 (it had drifted by 42 files); **no file sealed yet** |
| `CLAUDE.md` | points at `SEALING.md` |
| package-graph guard | `package/inet/test/packagegraph.jl` asserts the dependency direction and the leaf rule |
| intra-package layering guard | still none — deferred by the component-package-split plan (S7); `SEALING.md` is the manual substitute |

The two requirements documents were drafted from what the done plans and the
code already practice. They have since been *used* — `packet-is-a-document.md`
cites `IR-MACHINES-ARE-DOCUMENTS` and proposes replacing one `IAR-` rule with
another — so P0 is now less about accepting them cold and more about ratifying
what practice has already adopted.

## 3. The layered/sliced architecture

Vocabulary as in [packages.md](../../documentation/packages.md), which is the
same in all three repositories: a **slice** is a top-level division holding one
package stem (`package/<slice>/`); a **layer** is an ordered stratum inside a
package; a **module** is the import boundary. The package graph, from
[architecture.md](../../documentation/architecture.md):

```
InetPacket ──┬────────────► InetQueuing ──┬──► Inet (umbrella)
             └────────────► InetLinkLayer ┘        │
InetCommon ───────────────► InetQueuing ──► InetRunner
                                                   │
                                            InetRepl (leaf — nothing
                                                      may depend on it)
```

plus one-way dependencies on `OmnetppSimulator`/`ProjecturedKernel` from
`common`, `queuing` and `linklayer`; `Inet` also takes `ProjecturedVisual` for
the packet diagram, and `InetRunner` takes `InetQueuing` and
`OmnetppSimulator`. The expected future edge `linklayer → queuing` (modular
Ethernet) keeps the graph acyclic. `packagegraph.jl` asserts all of it.

Layers and slices within the packages, encoded as the group structure of
`SEALING.md`:

- **`InetPacket`** — one module (`PacketModule`), one slice; the internal file
  order (bit lengths → quality → chunks → peek → IO → headers → tags →
  envelope → buffers → inspection) is its layer order in miniature.
- **`InetCommon`** — one slice, `lookup`.
- **`InetQueuing`** — five layers: *contract* (the packet protocol as generic
  functions) → *base* (shared element machinery) → *elements* (slices:
  source, sink, queue, server, classifier, scheduler, filter) → *composition*
  (plumbing, marking, compound modules) → *model* (`QueuingModel`,
  `QueuingCapture`).
- **`InetLinkLayer`** — one protocol slice, `t1s`, with its own internal order
  (frame → wire → phy → junction → plca → mac → app → model → capture); a
  second protocol arrives as a sibling slice, not a package.
- **`Inet`** — the umbrella, the catalog and the packet diagram.
- **`InetRunner`** — the command line and the executable built from it.
- **`InetRepl`** — the leaf; audited against the leaf rules of `packages.md`.

Outside `package/`: `tool/` (the FSM generators, the header inventory, the
build description) and `watch/` (live views), each its own environment —
audited as Wave B; the root `test/runtests.jl` harness with Wave C.

## 4. What is about to be rewritten — the gates

The audit of a group must not run while a plan is about to rewrite it. Sealing
a file that a pending plan will rewrite spends the audit twice and puts a seal
in the way of planned work.

**Landed since this plan was written**: `observable-communication` (the two
capture files and their test phases), `fsm-mac` (P7b, `cbe605b`), the
`queuing-tutorial` (the `InetQueuingExample` package, `PacketPredicates.jl`,
`PacketMarking.jl` and the `queuing`-main element edits), and the `headers`
work. All are ordinary unsealed entries in `SEALING.md` now.

Open gates, by the rung they block:

- **`packet-is-a-document.md` is implemented, and the rule it challenged is
  now the rule.** Every packet type is a ProjecturEd document, `InetPacket`
  depends on `ProjecturedKernel`, and
  [IAR-PACKET-DEPENDS-ON-NOTHING](../../documentation/architecture-requirements.md)
  is replaced by
  [IAR-PACKET-DEPENDS-ON-THE-DOCUMENT-SUBSTRATE](../../documentation/architecture-requirements.md#iar-packet-depends-on-the-document-substrate).
  The owner's constraint held: no reactive instance and no selection field on
  the hot path, and every phase 0 allocation number reproduces exactly. P0.2
  below is now ratification of a rule the code already meets rather than a
  choice between two. The `packet` rung is auditable.
- **`protocol-header-inventory.md` is done and `protocol-header-gallery.md` is
  done through stage 2.** The inventory took `protocol/` from 19 files to 38
  and the declared wire formats to 354; the gallery added `HeaderFacts.jl` to
  `packet` and a `headerview/` slice to `inet`, and its stage 3 is optional and
  waits on a reader rather than on code. Neither gates the `packet` rung any
  more — but audit `protocol/` knowing it is now the larger half of the
  package.
- **`queueing-tutorial-from-ned-ini.md`** — rebuilds the tutorial's steps from
  NED/INI sources; gates the `queuing` example rung (Wave D).
- **`queuing-model-migration.md`** — wave 2 of the element library
  (WRR/token/buffer/cloner families); gates the `queuing` element rungs
  whenever it resumes.
- **`executable-options.md` and `executable-with-user-interface.md`** — both
  reshape `runner`; audit that package only after they settle.
  `executable-options.md` has one phase left and it belongs to the other plan.
  `package-convention-repl-leaves.md` is **done** and no longer gates `repl`.
  No side branch exists: everything named here is on `main`.

That leaves `packet`, `common`, `linklayer`, the `queuing` contract, base and
composition layers, and `repl` as the rungs actually available now — a much
wider front than when this plan was written, because three of the five gates
have cleared.

## 5. Phase 0 — ratify the requirements documents

- [ ] **P0.1** Owner review of `documentation/requirements.md`: each `IR-…`
  accepted, reworded, or dropped. Note that later plans already cite these IDs,
  so review is ratification, not adoption.

  **The two that were flagged are settled: keep both, as written** (owner
  decision, 2026-08-12).

  - `IR-TAGS-TRAVEL` stands as a requirement even though the models exercise it
    thinly. The mechanism is complete — `RegionTagSet`, `add_region_tag!`,
    `region_tags`, `shift_region_tags!` and `clip_region_tags!` in
    `package/packet/main/Tags.jl`, with push and pop shifting the ranges
    eagerly — and the packet tests prove the surgery. Three model files use
    tags today (`base/PacketSource.jl`, `composition/PacketMarking.jl`,
    `t1s/App.jl`), and no stack here encapsulates across layers yet. The
    requirement is what the models grow toward, not a description of them.
  - `IR-TUTORIAL-IS-LIVE` keeps its general statement, illustrated by the
    queueing tutorial in its **Better** paragraph. It is not narrowed to that
    one tutorial.
- [ ] **P0.2** Owner review of `documentation/architecture-requirements.md`,
  16 rules. The packet question is settled in the document already:
  `IAR-PACKET-DEPENDS-ON-NOTHING` is gone,
  `IAR-PACKET-DEPENDS-ON-THE-DOCUMENT-SUBSTRATE` is in, and `InetPacket`'s only
  dependency is `ProjecturedKernel`. So the `packet` rung is auditable and the
  review is ratification.

  **`IAR-FOUR-STRUCT-ELEMENT` is dropped** (owner decision, 2026-08-12). It said
  an element is four structs — `…Parameters`, `…States`, `…Statistics`,
  `…Module` — and cited `package/queuing/main/queue/PacketQueue.jl:69-119`.
  None of that held after
  `plan/done/queuing-elements-on-the-module-macro.md` put all seventeen module
  kinds onto `@simulation_module`, whose `@parameters`, `@gates`,
  `@statistics`, `@submodules` and `@connections` sections declare each field
  by its kind. Restating the rule over those sections was the alternative and
  was not taken: the macro is what an element is written with, so a requirement
  repeating the macro's own shape earns nothing. What the rule carried and the
  document no longer states is *why* the kinds are separate — a parameter is
  shareable across runs, run state is what a fresh build re-creates per
  execution, a statistic is what recording touches. That reasoning now lives
  only in the macro's docstring, in `omnetpp-julia`. Wave A4 audits an element
  against the macro's sections and against
  [IAR-ZERO-COST-RECORDING](../../documentation/architecture-requirements.md#iar-zero-cost-recording),
  which is untouched.

  Lesser candidates flagged at drafting: `IAR-TESTS-IN-PHASES` (convention or
  requirement) and `IAR-ACYCLIC-GROWTH` (subsumable into
  `IAR-LOWEST-PACKAGE`).
- [ ] **P0.3** Decide the layering-guard question deferred by the
  component-package-split plan (S7): build a static intra-package guard now
  (model: `projectured-julia`'s `check_layering`) or keep `SEALING.md` as the
  only intra-package enforcement — `packagegraph.jl` already covers the
  package graph — until `queuing`/`linklayer` grow more layers.
- [x] **P0.4 `SEALING.md` re-synced** (2026-08-10). The inventory had drifted
  by 42 files: the `runner` and `repl` packages, the landed
  `InetQueuingExample`, `PacketMarking.jl`, new test phases and new `tool/`
  files. All are entered at their include positions. Group names still need
  reconciling with whatever P0.1–P0.3 change (renaming groups is allowed;
  reordering entries is not).
- [x] **P0.5 Layout alignment — executed** (2026-08-12).
  [folder-layout-alignment.md](../done/folder-layout-alignment.md) is done and
  moved. `common/` is retired: the predicates went to `base/`, and the
  plumbing, the marking and the priority queue went to a new `composition/`.
  The plan had called that folder `compound/`; the elements that landed since
  made the name false, and `composition` is what §3 above and `SEALING.md`
  already call the layer. Four leave-as-is decisions are recorded.
  `SEALING.md` carries the four new paths in their original positions, so
  waves A4 and A5 audit final paths.

## 6. The audit waves

Wave A walks `SEALING.md` top to bottom — the topological order. Per-wave
notes:

| wave | group | gate | watch for |
| --- | --- | --- | --- |
| A1 | `packet` | open — the rule it waited for is in the document | normalization only via smart constructors; quality lattice propagation; no simulation vocabulary anywhere. 23 root files plus 38 in `protocol/` — the slice grew from 19 while the inventory ran |
| A2 | `common/lookup` | open | neutrality: knows the simulator's vocabulary, never a protocol's |
| A3 | `queuing` *contract* | open | generic-function vocabulary — no interface types; bodiless declarations only (upstream interface-declares-only rule) |
| A4 | `queuing` *base* + *elements* | queuing-model-migration wave 2 | four-struct convention per element; push/pull duals honest; the landed policy presets |
| A5 | `queuing` *composition* + *model* | open — P0.5 landed | compound modules are elements; `QueuingModel` against the lifecycle contract; the folder is `composition/` now |
| A6 | `linklayer` `t1s` | open | derive-don't-transliterate boundary documented per file; generated files: provenance header, regeneration reproduces byte-for-byte, golden hashes unchanged; `recorder === nothing` guards on every emission site |
| A7 | `inet` umbrella | open | re-exports, the catalog and the packet diagram only; re-exports nothing from `OmnetppSimulator` (explicit dual imports, per README) |
| A8 | `runner`, `repl` | **blocked** — the three executable plans | the leaf rules of `packages.md`: nothing depends on a `Repl`; `@compile_workload` only in a leaf |
| B | `tool/`, `watch/` | open | generators audited together with their `⚙️` outputs (regenerate → byte-identical → hashes reproduce); watch scripts against the substrate's presentation-placement rules |
| C | test packages + root harness | follows each main package | phase files individually meaningful; golden hashes and comparison harness in the right phases; `packagegraph.jl` as the guard it is. **Two known errors to fix here**: `phase5_capture.jl:25` and `:88` read `Capture.buffer`, which `omnetpp-julia` renamed to `buffers` — the tests have drifted from the substrate, not the other way round |
| D | example packages | queueing-tutorial-from-ned-ini | `InetQueuingExample`, `InetPacketExample`, `InetExample` |

## 7. The per-file audit procedure

Same protocol as the omnetpp-julia campaign, with the binding set for this
repo: `documentation/architecture-requirements.md` (`IAR-…`) plus transitively
`OAR-…` (omnetpp-julia) and `AR-…` (projectured-julia).

1. Introduce the next file; audit immediately; report the audit before any
   seal talk.
2. Checklist: docstring contract; naming; imports name exported symbols only;
   layer/slice edge direction; lowest-home placement; no dead code; event-path
   files against the determinism rules; recording behind the
   `recorder === nothing` guard; generated files never hand-touched; tests at
   the smallest scope (per-package suites from CLAUDE.md).
3. Fix, verify with the smallest suite, seal on compliance or accepted
   non-compliance, flip `⬜` → `🔒` in the same commit.
4. Violations in already-sealed files: report, ask, then fix.

Working conventions: fixes in a dedicated sibling worktree
(`inet-julia-audit`; `[sources]` are relative — sibling placement is
mandatory, `Pkg.instantiate()` on creation), one commit per audited file or
small group, merged back `--ff-only`. Pure seal-flips may go straight to
`main`.

## 8. Cross-repo coordination

The omnetpp-julia campaign now walks that repository's
`simulation-anatomy.md` — thirty-eight layers, thirty-six of them sealed as
specification. This repository has no anatomy; its ladder is the package graph
above. The dependency between the campaigns is therefore by *layer*, not by
wave number: a rung here follows the anatomy layers it is built on — the
module and event layers before `common`/`queuing`, the recording and capture
layers before this repository's capture files. `InetPacket` depends on no
substrate layer at all, so its only gate is P0.2.

Findings that blame a substrate contract are filed against the substrate file
in its own campaign, not patched around here. Where an audit here finds the
substrate's anatomy wrong, that is a finding against the anatomy — report it
there rather than working to a contradiction.

## 9. Progress

- [x] Recon; `SEALING.md`, `requirements.md` (12 `IR-…`),
      `architecture-requirements.md` (17 `IAR-…`), `CLAUDE.md` (2026-08-04)
- [x] Inventory re-synced after 165 commits — 42 missing files entered
      (2026-08-10)
- [x] Refreshed against the current package graph and pending plans
      (2026-08-10)
- [x] Refreshed again against the eight pending plans and the code
      (2026-08-12): three gates cleared, and `IAR-FOUR-STRUCT-ELEMENT` found to
      contradict the package it governs
- [x] P0.5 layout alignment — executed 2026-08-12
- [x] `IAR-FOUR-STRUCT-ELEMENT` dropped — owner decision, 2026-08-12. 17 rules
      become 16
- [ ] P0.1 / P0.2 ratify the requirements documents — the packet question is
      already settled in the document, and the one rule that contradicted the
      code is gone, so what remains is the reading itself
- [ ] P0.3 layering guard
- [ ] A1, A2, A3, A5, A6, A7, A8 and Wave B — the rungs open now
- [ ] A4 — behind wave 2 of `queuing-model-migration.md`
- [ ] Waves C and D

**Still zero of 223 files sealed.** Nothing in the campaign is blocked by code:
what it waits on is P0.1 and P0.2, which are the owner's to answer.
