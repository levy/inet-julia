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

### Phase 0 — the macro, in `omnetpp-julia` — **done**

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

Landed as `omnetpp-julia` `eb8caf1` and `c924c1b`, with 56 tests. The simulator
suite stays at 5892.

**What the macro must qualify.** Generated code runs in the module that wrote
the declaration, so every name it emits has to be reached from there.
`module_gates`, `input_gate`, `output_gate` and `Gate` were emitted bare and
resolved in the caller. They are now written through an interpolated module
object. A function object cannot be interpolated into definition position, so
the macro builds `Expr(:., ThisModule, QuoteNode(name))` instead.

**A docstring needs `Base.@__doc__`.** A macro that expands to a block cannot
take a docstring without it.

### Phase 1 — one real element, end to end — **done**

`ActivePacketSource`. It has all five kinds — parameters, a stream, a timer
variable, statistics, one gate — so it settles §4's three questions on the
smallest thing that exercises them.

Landed as `cd48ab4`. `test_queuing()` is 275 passed, 2 errored, which is the
baseline on untouched mains: both errors are `record_tap!`, and `omnetpp-julia`
main has moved ahead of what this repository's capture seam expects.

**A gate needs its annotation before any lookup.** `InterfaceClaim` is read off
the gate while the wiring is walked, so it cannot wait for initialization. The
macro's constructor now calls `decorate_module!` last, and an element that
claims an interface defines that one method:

```julia
NetworkModule.decorate_module!(m::ActivePacketSourceModule) =
    (push!(m.out.annotations, InterfaceClaim(ActivePacketSource)); m)
```

**The check written above was too strong.** It said a test that had to change is
a fault. Construction calls and field reads necessarily change — that is the
port. The invariant that did hold, and the one to keep for every wave, is:
**no assertion changed**.

**The call sites are the bulk of the work.** One element of seventeen moved 67
sites across ten files. They cannot be deferred to Phase 7 as this plan first
said, because the suite only stays green if an element's call sites move with
it. That is what §5.1 is for.

### Phase 1.5 — the transformer — **done**

`tool/port_to_module_macro.jl`, with `tool/test_port_to_module_macro.jl` beside
it. At roughly 300 sites left over sixteen elements, the rewrite has to be a
program.

**A textual rewrite is not safe here.** `source` names an active source in one
test set and a passive sink in the next, so the same characters must be changed
in one place and left alone in the other. Only the receiver's type decides.

So the tool parses with `Base.JuliaSyntax`, infers the type of every receiver,
and splices text at the byte ranges the parser reports. What it infers, and why
each one is needed by the queuing tests:

| from | it learns |
| --- | --- |
| `m::PacketQueueModule` in a signature | the receiver of a method body |
| `x = T(…)`, `x = add_module!(net, T(…))` | a local, in the scope that holds it |
| a builder that answers `(; network, source, sink)` | the type of `chain.source` |
| a comprehension or a vector of modules | `sources[1]` and `for s in sources` |
| `all(s -> …, sources)` | the parameter of a lambda over a collection |
| `given === nothing ? make_one() : given` | the branch that is known |

A test set is a scope in Julia, which is why the scope-aware scan is right and
not merely a heuristic.

**What it refuses, it names.** An unresolved receiver, a field the declaration
does not have, a call with a comment between its arguments, a retired name
outside an import list — each is reported with its file and line and left
alone. A rewrite that does not parse never reaches the working tree.

**How it was proven.** The hand-made Phase 1 was reverted and redone by the
tool: 67 rewrites, nothing refused, and every one of the ten files parses to
the same expression as the hand-made version. Its formatting is better, so its
output was kept.

Run it after each element is declared by hand:

```
julia tool/port_to_module_macro.jl            # report, change nothing
julia tool/port_to_module_macro.jl --apply    # write the files
julia tool/test_port_to_module_macro.jl       # the tool's own tests
```

It takes no element argument. It finds what is ported by reading the
`@simulation_module` declarations in the tree.

### Phases 2 to 5 — the rest of the simple elements

Four waves, each ending green, in the order the elements were built:

| wave | elements |
| --- | --- |
| 2 | `PassivePacketSource`, `PassivePacketSink`, `ActivePacketSink` — **done** |
| 3 | `PacketQueue`, `PacketServer`, `InstantServer` — **done** |
| 4 | `PacketClassifier`, `PacketScheduler`, `PacketFilter` |
| 5 | the six `common` elements |

Each wave is the same three steps:

1. Declare the elements by hand: delete the `Parameters`, `States` and
   `Statistics` structs and the resets beside them, and write the sections.
   Diff each hand-written reset before deleting it, per §7.
2. Run `julia tool/port_to_module_macro.jl`, read the report, then `--apply`.
   Nothing may be refused; a refusal is either a site to fix by hand or a rule
   the tool is missing.
3. `test_queuing()` back to the baseline, and no assertion changed.

**What the transformer cannot see.** A method body that aliases a container —
`states = m.states`, `parameters, states = m.parameters, m.states` — reads the
field off the local afterwards, and the tool only rewrites a
`receiver.container.field` chain. Rewrite those bodies by hand in step 1, as
part of writing the declaration. Every element of wave 2 had one.

**Wave 2 findings.**

*The generated reset writes the recording handle back.* A hand-written
`reset_statistics!` left `recording` alone; the generated one writes every
statistic back to what it was declared as, and the handle is declared a
statistic. This is safe, because `run_network!` calls `initialize_network!` and
`register_network_statistics!` on every run, so a reset is always followed by a
fresh registration. It is safe by an ordering rather than by construction, so
`phase1_sources_sinks.jl` now pins it: record, reset, record again.

*The NED hooks collapse as an element ports.* §7.3 said to do this at the end.
Wave 2 forced it, because the two sinks lost the `Parameters` struct that
`ned_parameters_type` pointed at. `ned_parameter_fields` and `build_ned_module`
in `omnetpp-julia` now fall back to `collect_module_parameters` and to
`T(name; values...)`, so a kind written with `@simulation_module` needs no hook
at all. Both sink hooks are gone; `PacketQueue` and `ActivePacketSource` keep
theirs, the first for a unit conversion and the second for `PacketTemplate`.

*The baseline moved to 278 passed, 2 errored*, from the three assertions the
reset guard adds. The two errors are still `record_tap!`.

**Wave 3 findings.**

*A parameter struct that is passed around, not just constructed in place.*
`PacketQueueParameters` was a value in its own right: held in a variable, chosen
by a ternary, handed to `priority_queue` as `queue_parameters` for every level.
A keyword set replaces it, as a named tuple that is splatted —
`PacketQueueModule(name; parameters...)`. This is the compound's public
interface, so Phase 6 inherits it rather than deciding it.

*Two rules the transformer gained, both paid for by this wave.* A struct
declaration says what its fields hold, so `sum(q -> q.statistics.num_dropped,
m.queues)` resolves from `queues::Vector{PacketQueueModule}`. And a signature
binds its receiver for any struct the tree defines, not only for a ported
element, which is what lets a compound under `AbstractCompoundModule` be a
receiver at all.

*One bug the transformer's own guard caught.* Two retired names next to each
other in one import list produced two cuts that overlapped on the comma between
them. `apply_edits` refused to write, which is what it is for. Neighbours now go
in one cut.

*What stays unknowable.* `only(m for m in network.modules if module_name(m) ===
:queue)` picks a module out of a list by name. No inference reaches that, and
the two sites in `nedini.jl` were rewritten by hand.

### Phase 6 — the compound

`PriorityQueue`, onto `@submodules` and `@connections` of §11. This is the first
use of the composition half of the macro, and the first check that a `for` block
inside `@connections` generates the wiring a hand-written constructor does.

### Phase 7 — what stops being hand-written

1. Delete the `Parameters`, `States` and `Statistics` structs the macro replaced,
   and the `reset_states!` and `reset_statistics!` beside them. Waves 2 to 5 do
   this per element, so what is left here is whatever no wave owned.
2. `QueuingModel`, the demo builders under `example/steps/` and the catalog all
   construct elements directly. The transformer moves these with each wave, so
   what is left here is only what it refused.
3. **Collapse the NED reader's hooks.** Done as the elements port, from wave 2
   on: the builder falls back to `collect_module_parameters`, so a hook is
   needed only where a NED parameter maps to something other than a field.
   `ActivePacketSource`'s `PacketTemplate` is one such case. What is left here
   is to check that no hook survives whose element no longer needs it.
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
