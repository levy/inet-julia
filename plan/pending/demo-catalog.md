# The demo catalog

A browsable, self-serve demo of inet-julia for colleagues: one `demo.json`
doctype root file that loads everything it needs and builds the document in
memory; the catalog of features always visible on the left, the selected
demonstration on the right. The machinery is shared with omnetpp-julia's
catalog — `CatalogShell`, `SimulationEmbed` panes, the marker language — and
is owned by `omnetpp-julia/plan/pending/demo-catalog.md`; this plan owns the
inet-julia content and the few pieces specific to it.

## What this catalog stands on

- **The queuing tutorial** (branch `queuing-tutorial`) — 21 finished step
  pages under `package/queuing/example/tutorial/`, the `TutorialShell` (to be
  promoted to `CatalogShell` in `OmnetppPresentation`), and the step-file
  convention (`"$doctype": "SimulationEmbed"`). The catalog does not duplicate
  the tutorial; it curates highlights and hands the reader into it.
- **The packet & chunk API** and its worked demo
  (`package/packet/example/packet_api_demo.jl`) — already structured as
  named, embeddable definitions.
- **The T1S/PLCA model** (`package/linklayer/main/t1s/`) with its scenario
  parameter, INET-named statistics, and the generated MAC/PLCA FSM documents
  (`tool/generate_mac_fsm.jl`, `watch/mac_fsm*.jl`).
- **`inet_simulation_catalog()`** — `QueuingModel` and `T1sModel`, the two
  models step files can name.

## Prerequisite

The three tutorial branches land first (the omnetpp-julia plan's P0 lists the
order and the rebase caveat). For this repo specifically: `queuing-tutorial`
merges to main, the tutorial's `root.json` doctype string follows the shell's
promotion, and the worktree's uncommitted `[sources]` redirect is dropped.

## Design

`package/inet/example/demo/demo.json`:

```json
{
  "$doctype": "CatalogShell",
  "index":    "index.md"
}
```

The demo lives in the umbrella's example package (`InetExample`) because it
spans packet, queuing and linklayer. Pages are ordinary markdown with
`file`/`definition`/`realize` markers; step files name models from
`inet_simulation_catalog()`.

### Starting it from the REPL

One call, from the environment the `ji` alias already loads:

```julia
julia> using InetExample

julia> run_demo()                        # opens the catalog in an SDL window
```

`run_demo(; backend = default_backend())` is exported by `InetExample`, built
exactly like omnetpp-julia's: load `demo/demo.json` through the doctype
loader, build the `CatalogShell` and its projection, `run_editor!`. A
`demo/run.jl` covers shell use. When both example umbrellas are loaded in one
REPL, qualify: `InetExample.run_demo()`.

### Selecting and reading

Same shell, same behavior as the omnetpp-julia catalog: the navigator on the
left lists what `index.md` links to, grouped by the index's `##` sections,
and never disappears; clicking an entry (or `Up`/`Down`) opens that page on
the right. The index — the pitch plus the table of contents — is the first
thing on screen. A page is a scrolling stack of live blocks: prose as prose,
embedded source as the live code it is, simulation cards as widgets that take
clicks. Pages are interned in the load session, so a simulation left half-run
is still half-run when the reader returns to it — and the tutorial pages the
catalog links into share that same session.

### How a page communicates

The same prose-first rhythm as the omnetpp-julia catalog, stated there in
full: prose that frames (what this is, why it matters), the artifact itself
(source via `definition`, a runnable card via `realize`, a chart), and prose
that directs — one concrete action and what to watch for. The index carries
the "How to read" preamble; the queuing tutorial's `index.md` already reads
this way and is the template.

One inet-specific piece: the **FSM page** wants the generated MAC FSM document
embedded and, ideally, lit by a running simulation the way `watch/mac_fsm.jl`
does it. The static FSM document embed is just `<<file(...)>>` on the
generated document; the live overlay needs the watch machinery repackaged as
an embed pane or a `realize`-able document — assessed in P3, static-first.

## The catalog

`index.md` sections and pages. Titles are working titles. For each page:
what is on screen, what it demonstrates, and how it communicates — what the
reader is told to do and what they see happen.

**The front page (the index itself)** — the pitch: INET's concepts, native in
Julia, on a deterministic kernel — protocols as readable code, packets as
structured values, and the model, the run and the results as one live
document. Then the "How to read" preamble and the grouped table of contents.

### The packet, taken apart

- [ ] *A packet is chunks* — **demonstrates:** the packet API's core idea —
      immutable, structurally-shared content under a mutable envelope; a
      thousand copies cost one payload; `dup` is O(1).
      **On screen:** prose; the build/broadcast/forward definitions embedded
      from `packet_api_demo.jl`, each followed by its `describe`/`dissect`
      output rendered as a code block; a closing aside that the dissection
      is a tree and a projected tree view of it is where this is headed
      (`Inspect.jl` was written for that).
      **The reader:** follows one payload through a broadcast to ten peers
      and a three-hop forward, and the prose keeps score of what was copied:
      envelopes, never bytes.
- [ ] *Headers declare their own bytes* — **demonstrates:** `@header` — one
      declaration yields the struct *and* its bit-exact codec; plus the
      reinterpretation guard that refuses a cross-type `peek` unless asked.
      **On screen:** prose; the `Ipv4Header` declaration embedded; the wire
      bytes of a packet shown next to the fields they encode; the guard
      tripping, and the `reinterpret = true` escape hatch.
      **The reader:** matches a field to its bytes by eye — the prose points
      at the TTL — then reads the guard's refusal and why an accidental
      reinterpretation should be loud.
- [ ] *Knowing what you know* — **demonstrates:** the quality lattice —
      `incomplete`/`incorrect`/`misrepresented` compose monotonically, and
      `peek` is strict by default: corrupted data must be asked for
      explicitly.
      **On screen:** prose; short embedded fragments — a sliced packet
      whose header is incomplete, the strict `peek` refusing it, the
      `incomplete = true` opt-in reading it anyway with the flags visible.
      **The reader:** mostly reads; this page argues correctness culture.
      The closing prose lands it: a protocol model that silently parses
      garbage is how simulators lie.
- [ ] *Reassembly without ceremony* — **demonstrates:** `ChunkQueue` and
      `ChunkBuffer` — straddling pops normalize, sparse segments merge,
      gaps and overlap policies are explicit values.
      **On screen:** prose; an embedded fragment feeding out-of-order
      segments into a `ChunkBuffer`, with `gaps`/`is_complete_range` output
      shown after each insertion, then `assembled_chunk` at the end.
      **The reader:** watches the gap list shrink insertion by insertion in
      the shown output. The prose notes the three overlap policies and when
      a real protocol wants each.

### Queuing, element by element

- [ ] *The M/M/1/K chain* — **demonstrates:** the queuing element library in
      its canonical arrangement — source → queue → server → sink — and the
      project's validation culture: measured against closed form.
      **On screen:** prose; the network-builder source embedded from
      `QueuingModel.jl` (the same fragment the tutorial's Queue step uses);
      a run card; a chart comparing the measured queue statistics against
      the analytic M/M/1/K curve, with Little's law called out.
      **The reader:** presses Run, then raises `arrival_rate` toward
      `service_rate` and runs again — the queue grows, the measured points
      track the curve. Closing prose: the phase-1 test suite makes this
      same comparison, every run.
- [ ] *Backpressure is a conversation* — **demonstrates:** the four-role
      gate contract (push/pull × active/passive) and backpressure as a
      first-class refusal, not a drop.
      **On screen:** prose explaining the contract in plain words; a card
      with a refusing filter in front of a bounded queue, its counters
      showing the producer stalling instead of the queue dropping; the
      filter's one-line predicate embedded as code.
      **The reader:** runs, watches the produced-vs-consumed counters
      diverge and then hold, flips the filter's `backpressure` parameter to
      the silent-sieve mode, runs again, and sees drops instead of stalls.
- [ ] *The whole tutorial* — **demonstrates:** the 21-step interactive
      queuing tutorial — itself a major deliverable — without duplicating
      it.
      **On screen:** a short page saying what the tutorial is and how it is
      built (the same shell, the same markers — this catalog page is made
      of the same material it describes), with the tutorial's own index
      linked; a curated three (Queue, PriorityScheduler, Network) linked
      directly in this section.
      **The reader:** clicks into a step; the tutorial pages open in the
      same shell and the same load session, and the navigator brings them
      back.

### 10BASE-T1S, faithfully

- [ ] *A bus that takes turns* — **demonstrates:** a faithful IEEE
      802.3cg-2019 multidrop Ethernet — PLCA cycle arbitration on a real
      junction-chain bus — as readable Julia.
      **On screen:** prose on what PLCA is in five sentences; a run card
      for `T1sModel` whose form exposes `n_nodes`, the segment/stub delays
      and the `scenario` (`notraffic`/`bestcase`/`worstcase`); a chart of
      cycle length.
      **The reader:** runs `notraffic` and checks the pinned fact the prose
      states — the cycle is 18.001 µs, analytically derived and asserted in
      the suite — then switches scenario and node count and watches the
      cycle stretch.
- [ ] *Four state machines, generated* — **demonstrates:** the protocol's
      four FSMs (MAC, PLCA control, PLCA data, PHY) are documents — 
      generated, rendered, and navigable, with the running code generated
      from the same source.
      **On screen:** prose; the MAC FSM document embedded and rendered as a
      state diagram; the PLCA control FSM (14 states) beside or below it;
      a pointer at the generator (`tool/generate_mac_fsm.jl`).
      **The reader:** walks states and transitions with the caret. The live
      overlay — states lighting up while a simulation runs, as
      `watch/mac_fsm.jl` does — is this page's stretch goal (design note
      above); the page ships static and is already convincing.
- [ ] *The same numbers as INET* — **demonstrates:** parity is not claimed,
      it is measured — the model emits INET's own signal names and the
      comparison against a real INET `.vec` run is a harness, not a slide.
      **On screen:** prose; the statistics wiring embedded (a few of the 22
      INET-named signals); a chart overlaying a Julia-run vector with the
      corresponding INET reference series where a reference file is
      present.
      **The reader:** reads the honest caveat the prose makes: producing
      the INET side is a manual step against a real OMNeT++ install, and
      the reference files are not yet in-tree; the harness
      (`compare_t1s_vectors.jl`) is what makes the claim checkable at all.

### Finding the module that answers

- [ ] *Interface lookup* — **demonstrates:** `find_module_interface` — a
      module finds its protocol peer by walking real connections or by
      reference, with claims and forwarding transparency, instead of
      hard-wired paths.
      **On screen:** prose; a short embedded fragment wiring three modules
      and resolving an interface through a forwarding claim; the resolved
      path shown.
      **The reader:** mostly reads; it is one small page, and it closes the
      catalog on an architectural note — the prose says why this replaces
      INET's string-path lookups and what that buys a refactoring model
      author.

## Phases

- [ ] **P0 — substrate lands** (prerequisite above; gated on the omnetpp-julia
      plan's P0–P2 for the shell and panes).
- [ ] **P1 — the pipeline stands**: `demo.json` + `index.md` + *The M/M/1/K
      chain* (reuses a tutorial step file) render and run; `run_demo()`
      exported from `InetExample`; `demo/run.jl` for shell use.
- [ ] **P2 — packet pages**: the four packet pages; `packet_api_demo.jl`
      refactored only as far as naming the definitions the pages embed.
- [ ] **P3 — T1S pages**: run card, FSM page (static embed first; assess the
      live overlay), statistics page.
- [ ] **P4 — tutorial hand-off + lookup page**: the tutorial section links,
      the lookup page.
- [ ] **P5 — test**: the walker (load `demo.json`, open every page, resolve
      every marker, drive each embed briefly), added to `InetTest`'s scope.

## Open decisions

- Whether the tutorial section lists all 21 steps in the demo index or links
  only the tutorial's own `index.md` as one entry. Listing a curated few and
  linking the rest keeps the catalog a catalog.
- The FSM live overlay: embed pane vs a bespoke realized document vs staying
  static. Static ships regardless.
- The packet pages show program *output* (dissections, gap lists) as code
  blocks — honest quotations, but quotations. If they drift-proof poorly,
  an evaluator embed (run the shown fragment, splice its output) is the
  general fix and would belong in the shared machinery.
