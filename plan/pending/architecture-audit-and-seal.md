# Architecture audit and seal

Status: pending (campaign plan, 2026-08-04)

## 1. Goal

Audit every file in `inet-julia` against the architecture requirements, fix
what the audit finds, and seal file by file — linearly, in dependency order.
The sealing state and rules live in [SEALING.md](../../SEALING.md) (created
with this plan); this plan is the campaign that walks it. The sibling campaign
in `omnetpp-julia` (`plan/pending/architecture-audit-and-seal.md` there) runs
the same protocol on the substrate.

## 2. What exists, what was missing

| artifact | state |
| --- | --- |
| `documentation/architecture.md` | good — package graph, placement rule, environments, testing |
| `documentation/requirements.md` | **created with this plan** (`IR-…`, 12 requirements) — needs owner review and acceptance in P0 |
| `documentation/architecture-requirements.md` | **created with this plan** (`IAR-…`, 17 rules) — needs owner review and acceptance in P0 |
| sealing protocol | none before this plan — `SEALING.md` is now authoritative |
| `CLAUDE.md` | existed; now points at `SEALING.md` |
| static layering guards | none — deliberately deferred by the component-package-split plan (S7); the resolver enforces the package DAG, nothing enforces intra-package layers yet |

Both new documents were drafted from what the done plans and the code already
practice (four-struct convention, generated-file provenance, zero-cost
recording, golden hashes, …) — the P0 review is about *accepting* them as
binding, and trimming or tightening, not inventing content.

## 3. The layered/sliced architecture

Vocabulary as in `projectured-julia`'s `documentation/terminology.md`:
package / layer / slice / module. The package DAG (from `architecture.md`,
unchanged):

```
InetPacket ──┬────────────► InetQueuing ──┐
             └────────────► InetLinkLayer ┼──► Inet (umbrella)
InetCommon ───────────────► InetQueuing ──┘
```

plus one-way dependencies on `OmnetppSimulator`/`ProjecturedKernel` from
`common`, `queuing` and `linklayer` (the `inet` umbrella depends directly only
on `OmnetppSimulator`). The expected future edge
`linklayer → queuing` (modular Ethernet) keeps the graph acyclic.

Layers and slices within the packages, encoded as the group structure of
`SEALING.md`:

- **`InetPacket`** — one module (`PacketModule`), one slice; the internal file
  order (bit lengths → quality → chunks → peek → IO → headers → tags →
  envelope → buffers → inspection) is its layer order in miniature.
- **`InetCommon`** — one slice, `lookup`.
- **`InetQueuing`** — five layers: *contract* (the packet protocol as generic
  functions) → *base* (shared element machinery) → *elements* (slices:
  source, sink, queue, server, classifier, scheduler, filter) → *composition*
  (plumbing, compound modules) → *model* (`QueuingModel`).
- **`InetLinkLayer`** — one protocol slice, `t1s`, with its own internal order
  (frame → wire → phy → junction → plca → mac → app → model); a second
  protocol arrives as a sibling slice, not a package.
- **`Inet`** — the umbrella and the catalog.

Outside `package/`: `tool/` (the FSM generators, own environment) and `watch/`
(live views, own environment) — audited as Wave B; the root `test/runtests.jl`
harness with Wave C.

## 4. In-flight branches — landing gates

**Landed since this plan was written**: `observable-communication`
(`t1s/T1sCapture.jl`, `QueuingCapture.jl`, `phase10_capture.jl`,
`phase5_capture.jl` — now ordinary unsealed entries in `SEALING.md`) and
`fsm-mac` (P7b, `cbe605b`).

Open gates:

- **`queuing-tutorial`** (worktree `inet-julia-tutorial`, ~30 commits ahead):
  large and active — phases A, B, D, E done; C partial (C4b live node badges
  outstanding); F partial. It adds the `InetQueuingExample` package and edits
  `queuing` main directly: `base/PacketSource.jl`,
  `classifier/PacketClassifier.jl`, `scheduler/PacketScheduler.jl`, plus two
  new files in the base/composition layers (`common/PacketPredicates.jl`,
  `common/PacketMarking.jl`). Gate: land it — or at least its `queuing`-main
  library edits — **before** waves A4–A5, else the audit reviews files a
  branch is about to rewrite. The tutorial-example package joins Wave D when
  it lands.
- **`demo-catalog`** (`plan/pending/demo-catalog.md`, new): builds a second
  demo on the tutorial machinery, and states that `TutorialShell` (which the
  `queuing-tutorial` branch puts in `package/queuing/example/`) is "to be
  promoted to `CatalogShell` in `OmnetppPresentation`". That promotion moves
  the shell — and presumably its widget projection — out of this repo, so
  sequence it before Wave D, or Wave D audits a package about to lose its
  shell.

## 5. Phase 0 — accept the requirements documents

- [ ] **P0.1** Owner review of `documentation/requirements.md`: each `IR-…`
  accepted, reworded, or dropped. Open questions to settle during review:
  should tag/region metadata (`IR-TAGS-TRAVEL`) stay a requirement while only
  partially exercised by current models; is `IR-TUTORIAL-IS-LIVE` scoped to
  the queuing tutorial or to all learning material.
- [ ] **P0.2** Owner review of `documentation/architecture-requirements.md`:
  each `IAR-…` accepted, reworded, or dropped. Candidates flagged during
  drafting: `IAR-TESTS-IN-PHASES` (convention vs. requirement),
  `IAR-ACYCLIC-GROWTH` (subsumable into `IAR-LOWEST-PACKAGE`).
- [ ] **P0.3** Decide the layering-guard question deferred by the
  component-package-split plan (S7): build a static intra-package guard now
  (model: `projectured-julia`'s `check_layering`) or keep `SEALING.md` +
  resolver as the only enforcement until `queuing`/`linklayer` grow more
  layers.
- [ ] **P0.4** Reconcile `SEALING.md` group names with whatever P0.1–P0.3
  changed (renaming groups is allowed; reordering entries is not).
- [ ] **P0.5 Layout alignment.** Decide and execute the folder moves in
  [folder-layout-alignment.md](folder-layout-alignment.md) (two moves inside
  `InetQueuing` — retiring the `common/` grab-bag and filing the compound
  queue with the compounds — plus four leave-as-is decisions to record).
  Gated on `queuing-tutorial` landing.

## 6. The audit waves

Wave A walks `SEALING.md` top to bottom — the topological order. Per-wave
notes:

| wave | group | watch for |
| --- | --- | --- |
| A1 | `packet` | empty-dependency invariant; normalization only via smart constructors; quality lattice propagation; no simulation vocabulary anywhere |
| A2 | `common/lookup` | neutrality: knows the simulator's vocabulary, never a protocol's |
| A3 | `queuing` *contract* | generic-function vocabulary — no interface types; bodiless declarations only (upstream interface-declares-only rule) |
| A4 | `queuing` *base* + *elements* | four-struct convention per element; push/pull duals honest; policy presets from the tutorial branch once landed |
| A5 | `queuing` *composition* + *model* | compound modules are elements; `QueuingModel` against the lifecycle contract |
| A6 | `linklayer` `t1s` | derive-don't-transliterate boundary documented per file; generated files: provenance header, regeneration reproduces byte-for-byte, golden hashes unchanged; `recorder === nothing` guards on every emission site |
| A7 | `inet` umbrella | re-exports and the catalog only; re-exports nothing from `OmnetppSimulator` (explicit dual imports, per README) |
| B | `tool/`, `watch/` | generators audited together with their `⚙️` outputs (regenerate → byte-identical → hashes reproduce); watch scripts against the substrate's presentation-placement rules |
| C | test packages + root harness | phase files individually meaningful; golden hashes and comparison harness in the right phases |
| D | example packages | after `queuing-tutorial` lands, including `InetQueuingExample` |

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

Ordering against the omnetpp-julia campaign: A1 (`packet`) is independent and
can start immediately; A2–A6 should follow the substrate waves they build on
(simulator core/model/configuration before `common`/`queuing`; simulator
result before the capture files). Findings that blame a substrate contract are
filed against the substrate file in its own campaign, not patched around here.

## 9. Progress

- [x] Recon: docs, plans, code maps, worktrees (2026-08-04)
- [x] `SEALING.md` created (Waves A–D, generated-file `⚙️` convention)
- [x] `documentation/requirements.md` drafted (12 `IR-…`)
- [x] `documentation/architecture-requirements.md` drafted (17 `IAR-…`)
- [x] `CLAUDE.md` wired to `SEALING.md`
- [ ] Phase 0 (P0.1–P0.4)
- [ ] Waves A1–A7
- [ ] Wave B
- [ ] Wave C
- [ ] Wave D
