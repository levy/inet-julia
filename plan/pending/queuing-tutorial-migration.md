# Migrating the INET queueing tutorial — a navigable document with live simulations

Status: **pending** (design draft, 2026-08-04). Implementation in dedicated sibling
worktrees, phase by phase, checkboxes ticked and decisions recorded here as we go.

## 1. Goal

Migrate INET's queueing tutorial (`inet-cpp/tutorials/queueing`: 49 steps of prose +
figure + NED network + INI config) into this repository so that:

1. **the whole content is navigable** — the tutorial is a projectured document; the caret
   walks from prose into an embedded code fragment into a running simulation and back;
2. **every simulation is configurable** — each step embeds a parameter form seeded with the
   step's configuration, editable in place;
3. **every simulation is runnable from the tutorial itself** — run/pause/reset controls and
   live results (progress, charts, topology) are part of the step, not a separate tool.

The architecture follows one directive: **the prose is ordinary markdown, and embed
markers — restricted Julia expressions — splice the document each evaluates to into the
parsed tree.** Embedding is therefore universal and visible — a Julia configuration
fragment, a raw JSON file, a live simulation object are each just what a marker's
expression returns — and the `.md` files stay git-friendly and readable outside the
editor (a marker degrades to a visible fenced block).

## 2. What exists, what is missing

Surveyed 2026-08-04 across the three repositories.

**Markdown + references (projectured-julia).** The markdown domain exists
(`package/domain/main/markdown/`: node types, hand parser, `MarkdownToSyntax` with
`:source` and `:rendered` styles). `MarkdownFile.populate_file!` **already parses**
```` ```pred-ref ```` fenced blocks containing `<<file("x")>>` markers into `ReferenceStub`s
(the walk covers every container node), and `resolve!` splices **by identity** — two markers
to the same file resolve to `===` objects, interned per load session
(`package/base/main/serialization/FileProject.jl`). The save path emits the marker back, so
round-trip never writes embedded content into the `.md`. What is missing:

- an embedded document renders as an **opaque marker fence** in both styles — neither
  `ReferenceStubToMarkdownSyntaxLeaf` nor `EmbeddedFileDocumentToMarkdownSyntaxLeaf` calls
  `print_child` into the target; the `:rendered` dispatcher has **no stub entries at all
  and errors** on one;
- **no selection descent** through the embed (the marker leaf has no reference mapping into
  the target's interior) — the precedent to follow is `WorkbenchEditor`'s tail pass-through
  (`.content.rest... => @reference ::WidgetScrollPane.content.^(rest)`) composed through
  `ChainingProjection.map_reference_forward`;
- **fragment references are rejected**: `resolve!` errors past the bare `FileReferenceStep`
  ("S5 territory") — a marker can name a file but not a place inside one. (This design
  routes around the limitation entirely: markers become restricted Julia expressions,
  §3.2.1, and `FileReferenceStep`/`IdentityReferenceStep` — a locator and a search wearing
  step costumes, not structural steps — fall out of use; a follow-up plan in
  projectured-julia removes them, §9);
- `MarkdownDocument` is absent from `NaturalToGraphics`'s dispatch table, so markdown
  content in a generic slot falls to the reflection fallback.

**The run pipeline (omnetpp-julia).** Everything needed to configure and run is already
document-shaped: `SimulationWorkflow` stages are `@document`s addressable by caret, buttons
fire operations, `parameter_form(space, assignment)` builds an editable form whose fields
write through to `ParameterBinding`s, `drive_simulation!` runs sliced at ~10 fps refreshing
reactive shadows (`SimulationExecutionView`, `SimulatorMonitor`, `sync_document!`), and
`VectorResultToGraphics` is a native reactive chart that repaints as samples arrive. The
`$doctype` project loader resolves `<<file(…)>>` stubs eagerly and realises JSON trees into
documents by reflection; `package/presentation/example/mm1k/` is the tested end-to-end
precedent (load `root.json` → configure → run → results, headless-verified). What is
missing:

- a **scoped embed**: the workflow projection is a monolithic full-window column
  (`SimulationWorkflowToWidget`, ~1300 lines); the parameter form, run controls and result
  chart cannot yet be rendered as one compact island inside another document (the
  domain-level pieces are decoupled; the reference-mapping is what is entangled);
- **several live simulations in one window** is unproven (each workbench owns its refresh
  hooks; no example drives more than one);
- the tutorial figures cannot be copied: `doc/media/*.png` is **gitignored and absent** from
  the checkout. Instead the network diagram can be **derived from the model** — the module
  layer's `Network` knows every module and connection, and the topology-graph pipeline
  (`SimulationTopologyToWidget`, Adaptagrams layout with grid fallback, layout frozen after
  first pass) already renders `(labels, edges)`.

**The content (inet-cpp).** Full step catalog captured in the exploration report: 49 steps
in 14 index sections, each = one `.rst`, one network in `QueueingTutorial.ned`, one
`[Config …]` in `omnetpp.ini`. Portability against wave 1 of the queuing migration:

- **(a) 15 steps portable today** with existing elements: the two source/sink pairs, Queue,
  DropTailQueue, PriorityClassifier, ContentBasedClassifier, PriorityScheduler, Filter1/2,
  Server, Delayer, Multiplexer, Demultiplexer, PriorityQueue, and the `Network` example
  (nested compounds of wave-1 elements only);
- **(b) 15 steps need specific elements**: WRR classifier/scheduler, Markov
  classifier/scheduler, a data comparator preset, ordinal-based dropper/duplicator,
  duplicator/cloner primitives, labeler + label classifier, and a named-preset registry for
  the two "generic plugin" steps;
- **(c) 19 steps blocked on subsystems**: tokens (10 steps incl. Telnet, LeakyBucket,
  TokenBucket, QueueFiller, RequestResponse), shared buffers (2), gates (2), RED (1),
  meters/taggers (3), transmitter/receiver link modules (2: the switching examples).

One cross-cutting content gap: many steps drive classification by **`packetData`** (a byte
value on the packet), which wave-1 `PacketTemplate` does not produce. INI value kinds a
form must cover: constants (with units), random expressions (`uniform`/`intuniform`/
`exponential` → `Volatile(...)`), strings, predicate expressions (→ Julia closures),
module paths (→ references), submodule-count integers, `typename` overrides (→
constructor arguments).

## 3. Architecture

### 3.1 The tutorial is a file project in the queuing example package

The tutorial is content, so it lives in inet-julia, in the queuing component's **example
package** (its first occupant):

```
package/queuing/example/            # InetQueuingExample (Project.toml; depends on
                                    # InetQueuing + OmnetppPresentation + Projectured)
  InetQueuingExample.jl             # step model builders + parameter spaces (the code
                                    # the tutorial embeds fragments of)
  steps/…                           # one Julia module file per step group, mirroring
                                    # the INET section structure
  tutorial/
    root.json                       # the project manifest ($doctype, <<file(…)>> refs)
    index.md                        # title page: sections, links to steps
    <section>/<Step>.md             # the prose, one file per INET .rst
    <section>/<Step>.json           # the step's runnable simulation ($doctype, see 3.3)
  run.jl                            # open the tutorial in the editor (mm1k-style)
```

`main/` must not depend on the presentation stack; the example package may. Step *models*
(network builders + parameter spaces) are ordinary example code — not shipped in
`InetQueuing` — and are what the markdown embeds fragments of. The tutorial is loaded with
the established `Projectured.load_project(…, "root.json", dir)` pipeline.

### 3.2 Markdown embeds everything (framework: projectured-julia)

Keep the shipped marker form — a fenced `pred-ref` block — but its body becomes a
**restricted Julia expression whose value is the document to splice**. No reference DSL,
no hidden search: the marker shows the actual computation.

1. **The marker language.** A marker body is parsed with the Julia parser and evaluated by
   a small interpreter allowing only **call chains with literal arguments** over a
   registered vocabulary — no assignment, no control flow, no arbitrary names — so a
   marker reads as plain Julia yet remains analyzable data. The vocabulary is the
   extension seam; each function is registered by the package owning its machinery:
   - `file("path")` (base, backed by the project loader) — the parsed file document,
     interned per load session, cycle-safe via placeholder pre-registration;
   - `definition(doc, "name")` (Julia domain) — the named top-level definition; functions,
     consts and structs already carry their names, duplicates error;
   - `realize(doc)` (presentation, §3.3) — the document a `$doctype` JSON tree describes.

   The marker contract: a marker stays a lazy stub holding its **source text verbatim**;
   saving emits that text back, never a re-print of the evaluated value; a marker that
   fails to parse or evaluate renders as its fence with the error — never wrong content.
   Interning lives in the vocabulary functions, so two markers evaluating the same
   expression yield the `===` document. Markers inside JSON string values (`root.json`)
   evaluate identically. The **reference layer is untouched**: references remain the
   structural-path currency of selections and iomaps, and the marker language never
   extends their syntax — the two pseudo-steps this replaces are removed by a follow-up
   plan (§9).
2. **Inline rendering.** Replace the opaque marker-leaf projections with rules that
   `print_child(recursion, …)` into the evaluated document through the type-dispatch
   fabric; an unresolved or failed marker renders as the fence (today's behaviour becomes
   the fallback). Both the `:source` and `:rendered` dispatchers get these entries —
   `:rendered` currently errors on a stub, which the tutorial cannot afford. `:source`
   keeps emitting the marker fence in `document_to_text` (the save path is by-marker,
   never by-content).
3. **Selection descent.** Give the embed rule a reference mapping that peels the markdown
   position and passes the tail into the child document unchanged (the
   `WorkbenchEditor.content` pattern), so the caret walks prose → embedded fragment →
   embedded simulation and back out.
4. **`MarkdownDocument` joins `NaturalToGraphics`'s dispatch table**, so markdown renders
   properly wherever a generic content slot holds it (the workbench content pane included).

Fragment example: `<<definition(file("../steps/queues.jl"), "packet_queue_step")>>` embeds
exactly one builder definition — how a step shows its configuration without quoting it.

### 3.3 The runnable simulation embed (framework: omnetpp-julia presentation)

A new small doctype in `OmnetppPresentation` — working name **`SimulationEmbed`** — is the
thing a step's marker refers to:

- **Document**: wraps a `SimulationWorkbench` targeted at one model type with a pre-seeded
  `ParameterAssignment` (the step's INI values) and a run limit (the step's
  `sim-time-limit`); plus display choices (which panes: form, topology, progress, chart;
  which result series is charted by default).
- **Projection**: one compact card, not the six-stage column — parameter form (extracted
  from `SimulationWorkflowToWidget`'s configure-stage card into a standalone,
  reference-mappable `ParameterFormToWidget`), **Run / Pause / Reset** buttons that drive
  the existing lifecycle operations (Run = configure → expand → instantiate → prepare →
  start under the hood; a validation error surfaces on the card), a live progress/counters
  row (`SimulationExecutionView`), the topology diagram (3.5) and the result chart
  (`VectorResultToGraphics`). Editing a parameter after a run and pressing Run again resets
  and re-runs — `reset_stages_after!` already gives the invalidation.
- **File form**: a step's simulation is a plain **`.json`** file whose root object carries
  `$doctype: "SimulationEmbed"` — the same generic object format `root.json` is written
  in. A `JsonFile` honestly stays a JSON document; **realisation is explicit**:
  `<<realize(file("Queue.json"))>>` embeds the live simulation, while
  `<<file("Queue.json")>>` embeds the raw JSON — two views of one interned file, which is
  how a step can teach the file format next to the running object. `realize` is the
  presentation's `$doctype` realiser exposed as a marker-vocabulary function: it interns
  per load session (two embeds of one step share the `===` live document) and remembers
  the realised ↔ JSON pairing so saving dumps back through it. Opening a project is the
  same function applied at the entry point (`load_project(dir)` ≡ `realize(file("root.json"))`).
  The `.pred` extension stays reserved for the binary serialization of the same document
  graph.
- **Many embeds, one window**: the tutorial shell keeps a registry of loaded embeds and
  refreshes them from the one per-frame hook; only embeds whose simulation is `Running`
  cost anything. Runs are started by the reader, so the common case is zero or one active
  engine; several running at once must merely stay correct, not fast.

`model` resolves by name through the existing doctype reflection against the catalog
modules (`Inet` included), exactly as `OmnetppProject.model` does today.

### 3.4 Steps are authored in Julia, shown as fragments

Each INET step's NED network + INI config becomes one **step builder** in the example
package: a named function constructing the network from `InetQueuing` elements plus a
`ParameterSpace` declaring what the step lets the reader vary (the INI's parameters, with
the INI values as defaults — constants as numbers, random expressions as
`Volatile(uniform(…))`/`Volatile(exponential(…))`/`Volatile(intuniform(…))`, predicate
expressions as Julia closures, module paths as references). The step's `.md` embeds the
builder *by fragment reference* — the reader sees the real, current source of the model
they are about to run, not a quotation that can drift. NED/INI originals are not carried
along: the Julia form *is* the model, per the migration's "derive, don't transliterate"
rule; where an INET idiom is worth pointing at, the prose says so.

### 3.5 Diagrams are derived, not copied — and live while the simulation runs

INET's tutorial figures are unavailable (gitignored) — and unnecessary. The kernel's
`Network` already knows every module, gate and connection, so the simulator grows one
derivation: `network_topology(network) -> (labels, edges)` feeding the model-interface hook
that `SimulationTopologyToWidget` renders. And because the diagram is derived from the very
model the step runs, it does not stop at structure: **while the simulation runs, the
diagram is live** — each node's badge shows that module's current state (a queue's length,
a source's packets produced, a busy server), refreshed by the embed's per-slice hook
through the same minimal-write shadow discipline the execution view uses. The layout is
computed once and frozen (the known live-editor trap); only the node contents are
reactive. Steps whose INET figure shows internals of a compound get that for free — the
compound's submodules are real modules in the network.

### 3.6 Navigation across the tutorial

Two levels, both document-native:

- **Within a step**: one `.md` = one step, embeds inline; the caret walks the whole page
  once 3.2's selection descent lands.
- **Across steps**: the tutorial opens in a master–detail shell — a navigator listing
  sections/steps (parsed from `index.md`'s structure) beside a content pane showing the
  selected step — reusing the workbench-editor pattern rather than concatenating 49 pages
  into one document. A `MarkdownLink` whose URL is a project-relative `.md` path acts as a
  step-switch in the shell (links keep working as plain links outside it). Lazy `resolve!`
  means a step's simulation loads the first time the step is shown.

The `:rendered` markdown style is the tutorial's reading mode; `:source` remains one
keystroke away for editing, embeds included, since both styles share the dispatch table.

## 4. Difficulties, and how the design answers them

1. **Opaque embeds / crashing `:rendered`** — the heart of the framework work (3.2.2); the
   tutorial is unbuildable without it, so it is Phase A and gated by tests that render a
   markdown file embedding a Julia fragment and a realised step `.json` in both styles.
2. **Fragment addressing that survives edits** — `definition(…)` (3.2.1) reads the name a
   definition already carries, so the marker survives reordering. Duplicate names and
   markers that no longer evaluate fail loudly at load, and the marker renders as its
   fence rather than wrong content.
3. **Selection across the splice** — solved once, in the markdown embed rule, by the
   established tail pass-through; every embedded domain then inherits it.
4. **Several live simulations** — registry + per-frame refresh (3.3); reader-driven runs
   keep concurrency low; correctness proven by a two-embeds-running test.
5. **Long runs vs. reactive charts** — `VectorResult.record!` is O(1) amortized since the
   in-place-append fix (`dbfb62a`), so chart cost is no longer a concern; what remains is
   memory on very long runs and the reader's time. The embed's run limit comes from the
   step, so a reader cannot accidentally start an unbounded run; a "capture vectors"
   toggle stays as the memory escape hatch for the two 1000 s switching examples.
6. **`packetData`** — add a `data` field to `PacketTemplate` (constant or `Volatile`),
   carried as a packet tag; content predicates and the comparator preset read it. Small,
   but a prerequisite for a third of the content.
7. **INET media absent** — moot by 3.5 (derived diagrams).
8. **INI `expr(…)`/plugin-class strings** — become Julia closures and named presets in the
   step builders; the "generic plugin" steps get honest prose: the Julia analog of
   `classifierClass = "inet::…"` is passing a function, and the step demonstrates exactly
   that.
9. **Steps needing missing elements/subsystems** — the tutorial ships in content waves
   mirroring the element waves of `queuing-model-migration.md`; the navigator lists
   not-yet-ported steps greyed with an honest "waits for the token subsystem" note rather
   than pretending completeness.

## 5. Correspondence to the INET tutorial

| INET | here |
|---|---|
| `doc/<Step>.rst` | `tutorial/<section>/<Step>.md` |
| `network <Step>TutorialStep` in `QueueingTutorial.ned` | a step builder function in the example package |
| `[Config <Step>]` in `omnetpp.ini` | the builder's `ParameterSpace` defaults + the step `.json`'s seeded assignment |
| `literalinclude` of NED/INI | fragment marker embedding the builder: `<<definition(file("…"), "…")>>` |
| `.. figure:: media/X.png` | derived topology diagram of the step's own network |
| `uniform(0s,2s)` etc. (volatile) | `Volatile(uniform(0,2))` parameter values |
| `expr(ByteCountChunk.data == 0)` | a Julia predicate closure over the packet's data tag |
| `classifierClass = "inet::…"` (plugin by name) | a function-valued parameter; named presets where INET has stock classes |
| `sim-time-limit` | the embed's run limit |
| index.rst sections / toctree | `index.md` structure → the navigator |

## 6. Migration recipe (per step)

1. Read the `.rst`, the step's network in `QueueingTutorial.ned`, and its `[Config]`.
2. Write the **step builder** in the example package: network of `InetQueuing` elements,
   `ParameterSpace` with the INI values as defaults (kinds per §5), run limit.
3. Write `<Step>.md`: title + translated prose (adjusting module names to the Julia
   elements and correcting the source's known slips), a fragment marker embedding the
   builder, and `<<realize(file("<Step>.json"))>>` embedding the live simulation.
4. Write `<Step>.json` (`$doctype: "SimulationEmbed"`): model + seeded assignment +
   panes + charted series.
5. Add the step to `index.md` under its section.
6. **Verify**: project loads; the step renders in both styles; the embedded simulation runs
   headless to its limit with a pinned golden hash; where the step demonstrates a
   quantitative claim (WRR ratios, RED drop growth), assert it on the recorded results.
7. Record deviations from the INET step here.

## 7. Work breakdown

Phases A–C are framework (parallelizable to a degree; A2/A3 before D); D onward is
content. Each phase = one commit series; tick + log here.

### Phase A — markdown embeds (projectured-julia)
- [ ] A1: embed rendering — resolved `FileDocument` renders its content via
      `print_child`; stub renders the fence; entries in **both** style dispatchers;
      `MarkdownDocument` added to `NaturalToGraphics`
- [ ] A2: selection descent through the embed (tail pass-through + iomap), test: caret
      walks md → embedded Julia fragment → back
- [ ] A3: save-path invariance test — embedding renders inline but `document_to_text`
      still emits the marker fence only

### Phase B — the marker language (projectured-julia)
- [ ] B1: marker bodies become restricted Julia — Julia-parse + interpreter over call
      chains with literal arguments, vocabulary registry; `file(…)` backed by the
      project loader (interning, cycle placeholders); the stub keeps its source text
      verbatim; parse/evaluation failure renders as the fence. Replaces the
      reference-path marker codec — `FileReferenceStep` falls out of use (§9)
- [ ] B2: `definition(doc, "name")` registered by the Julia domain — finds the named
      top-level definition (duplicates error)
- [ ] B3: round-trip: markers in `.md` and in JSON string values → parse → evaluate →
      render → save → byte-identical file

### Phase C — the simulation embed (omnetpp-julia)
- [ ] C1: `ParameterFormToWidget` extracted as a standalone, reference-mapped projection
- [ ] C2: `SimulationEmbed` doctype + compact card projection (form, Run/Pause/Reset,
      progress, chart) driving the existing lifecycle; validation surfaces on the card
- [ ] C3: `realize(doc)` registered in the marker vocabulary — the presentation's
      `$doctype` realiser as an explicit function: interns per load session, remembers
      the realised ↔ JSON pairing for save-back; step files are plain `.json`
- [ ] C4: `network_topology(::Network)` derivation + the embed's topology pane with
      **live node badges** — per-module state refreshed during the run via the embed's
      per-slice hook; layout frozen after the first pass
- [ ] C5: multi-embed refresh registry; test with two embeds, one running
- [ ] C6: headless integration test: markdown page embedding a fragment, a realised step
      `.json` and the same file raw, run to limit, assert results and selection walk

### Phase D — tutorial scaffold (inet-julia)
- [ ] D1: `package/queuing/example/` package (`InetQueuingExample`), `tutorial/root.json`,
      `index.md`, `run.jl`; master–detail shell with navigator from `index.md`;
      link-based step switching
- [ ] D2: `PacketTemplate` gains `data` (+ data tag; content predicates/comparator read
      it) — in `InetQueuing` main
- [ ] D3: first two steps end-to-end as the proof: `ActiveSourcePassiveSink` and `Queue`
      (prose, fragment, live sim, derived diagram, golden hash)

### Phase E — content wave 1: the 15 portable steps
- [ ] Sources and Sinks: `ActiveSourcePassiveSink`, `PassiveSourceActiveSink`
- [ ] Queues: `Queue`, `DropTailQueue`
- [ ] Classifying: `PriorityClassifier`, `ContentBasedClassifier`
- [ ] Scheduling: `PriorityScheduler`
- [ ] Filtering: `Filter1`, `Filter2`
- [ ] Serving: `Server`
- [ ] Generic elements: `Delayer`, `Multiplexer`, `Demultiplexer`
- [ ] Advanced queues: `PriorityQueue`
- [ ] Complex examples: `Network`
- [ ] `gettingstarted` → rewritten as the tutorial's introduction in `index.md`

### Phase F — element gaps + content wave 2 (15 steps)
New elements in `InetQueuing` (each ports its tutorial step(s) as the acceptance test):
- [ ] WRR classifier + scheduler presets → `WrrClassifier`, `WrrScheduler`,
      `PriorityQueue`-with-WRR, `CompoundQueue`
- [ ] Markov classifier + scheduler → `MarkovClassifier`, `MarkovScheduler`
- [ ] data comparator preset → `Comparator`
- [ ] ordinal dropper preset → `OrdinalBasedDropper`
- [ ] duplicator + cloner elements (+ ordinal duplicator preset) → `Duplicator`,
      `Cloner`, `OrdinalBasedDuplicator`
- [ ] labeler + label classifier → `Labeler`
- [ ] named-preset registry (a name → function catalog the form can offer) →
      `GenericClassifier`, `GenericScheduler`

### Later waves — gated on queuing subsystems (see `queuing-model-migration.md`)
- token subsystem → 10 steps (server, 4 generators, LeakyBucket, TokenBucket,
  QueueFiller, RequestResponse, Telnet)
- shared buffers → `Buffer`, `PriorityBuffer`
- gates → `Gate1`, `Gate2`
- RED → `RedDropper`
- meters/taggers → `Meter`, `Tagger`, `ContentBasedTagger`
- transmitter/receiver link modules → `InputQueueSwitching`, `OutputQueueSwitching`

## 8. Open decisions

- [ ] `SimulationEmbed` naming, and whether its card should optionally expand into the
      full six-stage workflow column (sweeps from within the tutorial) — start compact,
      single-run.
- [ ] Inline (non-fenced) marker syntax for small in-paragraph embeds — fenced blocks
      only for now; revisit if prose wants inline fragments.
- [ ] Markers *into* prose (addressing a markdown section for cross-step deep links — a
      `section(doc, "title")` vocabulary function, same pattern as `definition`) — not
      needed for the tutorial's first waves.
- [ ] How far the marker interpreter's subset may grow (today: call chains with literal
      arguments; the reserve position is sandbox-eval if genuine computation is ever
      wanted) — grow deliberately, per function, never to full eval by default.
- [ ] Whether the finished tutorial should also render to static HTML (the markdown is
      already the source; a marker could render as a code block + screenshot) — out of
      scope here.

## 9. Follow-up plans

- **Remove `FileReferenceStep` and `IdentityReferenceStep` (and `IdentityDocument`) from
  the kernel** — neither is a reference step in the sense the others are: a step descends
  one structural level, which is what selection propagation walks and iomaps map;
  `FileReferenceStep` is an entry-point locator with no default evaluation, and
  `IdentityReferenceStep` is an arbitrary-depth search over wrappers no domain produces.
  Their roles are `file(…)`/`definition(…)` in the marker vocabulary. Planned separately
  in projectured-julia (`plan/pending/remove-locator-reference-steps.md`), gated on
  Phase B landing (which removes their last consumer, the `FileProject` marker codec).

## Implementation log

(append per phase: decisions, deviations, golden hashes)
