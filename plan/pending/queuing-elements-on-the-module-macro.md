# Port the queuing elements onto `@simulation_module`

**Status:** design, not started (2026-08-08).
**Goal:** every element of `InetQueuing` declares its fields in the sections
that `simulation-anatomy.md` §10 and §11 define, and the macro generates what
is written by hand today.

**Why now.** The anatomy settled the form. §10 gives a field five kinds — a
parameter, a variable, a statistic, a gate, a stream — one seam per kind, and a
macro whose sections are the ones a NED file writes. Until that landed there was
nothing to port *onto*.

**What this replaces.** `queueing-tutorial-from-ned-ini.md` §4.1 decided this
("Migrate. Do not keep two forms.") and sketched it in four steps. This plan is
that decision, sized against the code and against the anatomy as it now stands.
Delete §4.1 when this plan is done, and leave that plan the tutorial work.

**Cross-repository.** Phase 0 is in `omnetpp-julia`, because the macro belongs
beside the module contract it generates for. Everything after it is here. The
`first-run-from-ned-ini.md` plan split the same way in the other direction.

---

## 1. What exists

Seventeen module kinds, sixteen simple and one compound:

| slice | kinds |
| --- | --- |
| source | `ActivePacketSource`, `PassivePacketSource` |
| sink | `ActivePacketSink`, `PassivePacketSink` |
| queue | `PacketQueue`; `PriorityQueue` is the compound |
| server | `PacketServer`, `InstantServer` |
| classifier, scheduler, filter | `PacketClassifier`, `PacketScheduler`, `PacketFilter` |
| common | `PacketMultiplexer`, `PacketDemultiplexer`, `PacketDelayer`, `PacketCloner`, `PacketDuplicator`, `PacketLabeler` |

Around them: 12 `Parameters` structs, 7 `States`, 15 `Statistics`, and
`reset_states!` or `reset_statistics!` written by hand in 11 files. Every one of
those is what the macro is supposed to stop a person writing.

## 2. The decision that keeps this incremental

**The macro generates the module contract that already exists.** It does not
introduce a second runtime.

`OmnetppSimulator.NetworkModule` gives `AbstractModule`, `Gate`, `add_module!`,
`connect!` and the two initialization stages, and every element implements that
contract today. `@simulation_module` emits a struct that satisfies it — a
`name`, a `module_id`, the gate fields — plus the seams and the generated
`reset_module!`.

So an element moves on its own, the suite stays green between elements, and no
element ever has to work twice. A big-bang port onto a new `SimulationModule`
runtime would need the whole anatomy first, and the first-run plan already
showed that is not necessary to make progress.

**What the macro does not touch is behaviour.** `initialize_module!`,
`start_module!`, `push_packet!` and the rest stay hand-written where they are.
This is a change to how fields are declared, and to nothing else.

## 3. What the macro generates

| from | it emits |
| --- | --- |
| the sections | one flat struct, fields in declaration order |
| `@parameters` | `collect_module_parameters`, and the fields |
| `@variables`, `@statistics` | `collect_module_variables`, `collect_module_statistics` |
| `@gates`, `@streams` | `collect_module_gates`, `collect_module_streams`, and gate construction with the owner set |
| `@signals` | `collect_module_signals` |
| the kinds together | `reset_module!` — write the variables and the statistics, leave the parameters |
| `@submodules`, `@connections` | the compound's constructor, per §11 |

Flat, not nested. A parameter's reference is the module's reference and the
field name, which is what lets an INI key address it with nothing in between.

## 4. Three questions to settle in Phase 1, on one real element

Settle them where they are visible, not in the abstract.

**Where the recorder handle goes.** `ModuleStatistics` holds `path`, `recorder`
and `vectors` — recording plumbing, not a measurement. It is not a statistic and
it is not a parameter. Either the macro emits it as a hidden field of every
module that declares a statistic, or it stays an ordinary `@variable`. Prefer
the first: nothing that declares a statistic can then forget it.

**What a stream is, yet.** An element carries `rng` and `seed` in its states and
re-seeds on reset. §5 makes a stream a kind with its seed as a parameter at a
reference, and §16 derives that seed. Neither exists. **Keep the current seeding
and declare the field a `@stream`**, so the kind is right and the derivation
arrives later without touching an element.

**Whether a parameter is immutable.** A flat struct makes every field mutable,
so "a parameter is written once at the build" becomes a discipline rather than a
type fact. Options are a check in the setter path, or `const` fields on the
generated struct — Julia allows `const` in a `mutable struct`. Try the second in
Phase 1; it costs nothing if it works.

## 5. Phases

Work in a worktree at `/home/projectured/workspace/inet-julia-module-macro`,
sibling to this checkout, and one at `omnetpp-julia-module-macro` for Phase 0.
Commit at each phase and mark it done here.

### Phase 0 — the macro, in `omnetpp-julia`

1. `@simulation_module` over the sections of §10: `@parameters`, `@gates`,
   `@variables`, `@statistics`, `@signals`, `@streams`, and the singular form of
   each.
2. The seven `collect_module_*` seams, and `reset_module!`.
3. `check_module` of §10: every field in exactly one section, and a default and
   a domain that fit the field's type.
4. Prove it on a throwaway element in `OmnetppSimulatorTest` — not on an INET
   element, because the engine stays free of model libraries.

The macro expands at definition time, so it raises none of the world-age risk
the NED reader's runtime type generation does. Keep it that way: no `eval` at
run time.

### Phase 1 — one real element, end to end

`ActivePacketSource`. It has all five kinds — parameters, a stream, a timer
variable, statistics, one gate — so it settles §4's three questions on the
smallest thing that exercises them.

Check: `test_queuing()` green, and the element's own tests unchanged. If a test
had to change, the macro changed behaviour and that is a fault.

### Phases 2 to 5 — the rest of the simple elements

Four waves, each ending green, in the order the elements were built:

| wave | elements |
| --- | --- |
| 2 | `PassivePacketSource`, `PassivePacketSink`, `ActivePacketSink` |
| 3 | `PacketQueue`, `PacketServer`, `InstantServer` |
| 4 | `PacketClassifier`, `PacketScheduler`, `PacketFilter` |
| 5 | the six `common` elements |

### Phase 6 — the compound

`PriorityQueue`, onto `@submodules` and `@connections` of §11. This is the first
use of the composition half of the macro, and the first check that a `for` block
inside `@connections` generates the wiring a hand-written constructor does.

### Phase 7 — what stops being hand-written

1. Delete the `Parameters`, `States` and `Statistics` structs the macro replaced,
   and the `reset_states!` and `reset_statistics!` beside them.
2. `QueuingModel`, the demo builders under `example/steps/` and the catalog all
   construct elements directly. Update the call sites.
3. **Collapse the NED reader's hooks.** `NedIni.jl` carries
   `ned_parameters_type` and `build_ned_module` only because a Julia element's
   parameters were somewhere the reader could not see. With
   `collect_module_parameters` they are. Drop both hooks for every element whose
   shape now fits, and keep `build_ned_module` only where a NED parameter maps
   to something other than a field — `ActivePacketSource`'s `PacketTemplate` is
   the case to check.
4. Remove §4.1 from `queueing-tutorial-from-ned-ini.md`.

Check: `test_queuing()`, and the NED and INI configurations of
`nedini.jl` still match the captured C++ results.

## 6. Out of scope

- `InetLinkLayer`. `T1sModel` builds a network by hand too, and it gets its own
  plan, as `queueing-tutorial-from-ned-ini.md` §4.1 already said.
- The anatomy's `SimulationModule` runtime, §12's model, §17's instance. The
  macro targets the module contract that exists.
- §5's seed at a reference and §16's derivation. Phase 1 keeps today's seeding.
- Making a statistic carry a unit or a recording mode. §28 will want it; nothing
  needs it yet.

## 7. Risks

- **A macro that generates a struct is hard to read when it is wrong.** Emit the
  struct, not a chain of helpers, and make `check_module` name the field and the
  section it failed in. A bad message here costs every element after it.
- **`reset_module!` becomes generated, and a hand-written one may have done
  more.** Diff each of the 11 by hand before deleting it. A reset that also
  cleared a cache and now does not is exactly the kind of leak
  `OAR-FRESH-BUILD-PER-EXECUTION` warns about, and it shows up as a second run
  that is plausible rather than wrong.
- **A `const` field in a mutable struct changes the struct's layout rules.**
  If Phase 1 finds it fights `reset_module!` or the constructors, drop it and
  keep the discipline instead. Do not spend the plan on it.
- **The statistics seam must not become a way to read a statistic from
  behaviour.** The kind exists partly so that "no behaviour reads a statistic"
  is checkable. Adding a convenient accessor would quietly remove that.
