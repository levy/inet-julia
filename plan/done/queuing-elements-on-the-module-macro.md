# Port the queuing elements onto `@simulation_module`

**Status:** done (2026-08-09). All seventeen module kinds of `InetQueuing`
declare their fields by kind, and the compound declares what it holds.
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
| `@submodules`, `@connections` | the compound's constructor, and `submodules` |

Flat, not nested. A parameter's reference is the module's reference and the
field name, which is what lets an INI key address it with nothing in between.

## 4. Three questions, and what they turned out to be

**Where the recorder handle goes** — *not* where this plan preferred. The idea
was a hidden field the macro emits for every module that declares a statistic,
so nothing can forget it. The macro cannot: `ModuleStatistics` is an INET type,
and the engine stays free of model libraries. So `recording` is declared a
`@statistic` like any other field, and every element writes the line.

That has a consequence the hidden field would not have had. A generated reset
writes every statistic back to what it was declared as, so it replaces the
recording handle where the hand-written `reset_statistics!` left it alone. It is
safe, because a run initializes and registers again, but it is safe by an
ordering rather than by construction. `phase1_sources_sinks.jl` pins it.

**What a stream is, yet** — as planned. `@stream rng::MersenneTwister =
MersenneTwister(seed)` with `seed` an ordinary parameter, so a reset re-seeds
from the same expression the build used. §5's seed at a reference and §16's
derivation arrive later without touching an element. One thing to note for them:
`markov_classifier` keeps a `MersenneTwister` in a closure, which is a stream no
module owns.

**Whether a parameter is immutable** — yes, and it costs nothing. A parameter
field is emitted `const`, which Julia allows in a `mutable struct`, so a later
write does not compile. Nothing in either repository writes a parameter after
the build, which is what the question was really asking. Settled after the
elements were ported, so there was a whole library to try it against rather than
one element.

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

**It stays after this plan.** `InetLinkLayer` builds its network by hand and
gets its own plan, and that plan wants this tool. Delete it when nothing in the
repository declares a `Parameters`, `States` or `Statistics` struct beside a
module any more.

### Phases 2 to 5 — the rest of the simple elements

Four waves, each ending green, in the order the elements were built:

| wave | elements |
| --- | --- |
| 2 | `PassivePacketSource`, `PassivePacketSink`, `ActivePacketSink` — **done** |
| 3 | `PacketQueue`, `PacketServer`, `InstantServer` — **done** |
| 4 | `PacketClassifier`, `PacketScheduler`, `PacketFilter` — **done** |
| 5 | the six `common` elements — **done** |

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

**Wave 4 findings.**

*A gate vector's size becomes a parameter.* The classifier and the scheduler
took their fan-out as a positional argument — `PacketClassifierModule(name,
outputs, …)`. The macro sizes a gate vector from an expression over the
parameters, so `outputs` and `inputs` are parameters now, and
`@gates out::Vector{OutputGate} = outputs` reads one. `per_output` is sized the
same way, and a reset re-evaluates `zeros(Int, outputs)` where the old code
filled the array in place. The effect is the same.

*The transformer refuses an extra positional, and it is right to.* Nothing says
which keyword `PacketClassifierModule(name, 2, …)` meant by its `2`. The seven
helper builders inside the two element files were rewritten by hand; no call
site outside them constructs either element directly.

*Neither element needed a stream.* `markov_classifier` keeps its own
`MersenneTwister` in a closure, which is a stream the module does not own. §16
will have something to say about that; nothing needs it yet.

**Wave 5 findings.**

*A ported element whose old constructor took a bare count was a silent hazard.*
`PacketMultiplexerModule(:mux, 2)` has no parameter struct to dissolve, so the
transformer passed over it and the call would have broken at run time with
nothing said. It now refuses a construction of a ported element that carries
any positional argument after the name, which found all nine sites. This is the
one gap in the tool that a wave discovered by nearly falling into it.

*A constructor's validation moves to `decorate_module!`.* The cloner checked
`outputs >= 1` before building. The generated constructor has no such seam, and
`decorate_module!` is called last with the module built, so the check reads
`isempty(m.out)` there.

*The multiplexer and demultiplexer kept a count with no `Statistics` struct
around it.* `num_packets` was a plain module field with a two-line
`reset_module!`. Declared `@statistic`, it needs neither.

**All sixteen simple elements are ported.** No `Parameters`, `States` or
`Statistics` struct is left in `package/queuing/main`, and there is no
hand-written `reset_states!`, `reset_statistics!` or `reset_module!` anywhere in
the package. That is §7.1 and §7.2 done as a byproduct of the waves.

### Phase 6 — the compound — **done**

`PriorityQueue`, onto `@submodules` and `@connections`. Landed as `omnetpp-julia`
`663ec4f` and the commit beside this line.

**Built against the contract that exists, not against §11's runtime.** §11 is
written for a constructor taking `(rules::ParameterRules, reference::Reference)`
and for `@set` and `@use` over inner parameters. §6 of this plan rules that
runtime out of scope, so the composition half made the same choice the field
half made: `@submodules` and `@connections`, and a submodule's values as
ordinary keyword expressions over the compound's parameters. That carries the
same information in the shape this contract can hold. `@set` and `@use` arrive
with the parameter rules, and this is what they will replace.

**A compound names its parts.** A submodule is named after the field it sits
at, and an element of a vector after the field and its index, because those are
the reference steps §11 defines. A builder that supplied a name no longer has
the say, so `priority_classifier(:classifier, …)` at the `classifier` field is
still `classifier`, and the level queues moved from `queue1` to `queues[1]`.
Five assertions in `TutorialTest.jl` name those paths and were updated. No
tutorial page does.

**Placing a compound places what it holds.** `add_module!` walks `submodules`,
so one call registers the compound and everything below it in declaration
order. A compound must therefore not register its own parts as well:
`TestCompound` in the simulator's own suite did, and errored at once.

**A submodule is not reset by the compound.** It is a module of the network in
its own right, so `reset_network!` reaches it; resetting it here would do it
twice and would throw away a submodule the wiring still points at.

`priority_queue(network, name, priorities; …)` survives as one call over the
constructor, so its four call sites did not move. Its `classifier` keyword maps
to the `given_classifier` parameter — the submodule field is `classifier`, and
a field and a parameter cannot share a name.

### Phase 7 — what stops being hand-written — **done**

This phase mostly did not need doing. Its four items fell out of the waves,
because an element's call sites have to move with it for the suite to stay
green — which is the one thing this plan first got wrong.

1. **The structs and the resets.** Gone with each element. Nothing in
   `package/queuing/main` declares a `Parameters`, `States` or `Statistics`
   struct, and no hand-written `reset_states!`, `reset_statistics!` or
   `reset_module!` is left in the package.
2. **The call sites.** Moved by the transformer with each wave, and by hand
   where it refused and said so.
3. **The NED reader's hooks.** Collapsed from wave 2 on, when the two sinks lost
   the struct `ned_parameters_type` pointed at. The builder falls back to
   `collect_module_parameters`, so a declared kind needs no hook.
4. **§4.1 of `queueing-tutorial-from-ned-ini.md`.** That section now records
   that the decision was carried out here, and names what is left: the compound
   is done, and `InetLinkLayer` still needs its own plan.

Two NED hooks survive, and both earn it: `PacketQueue` converts a NED `-1` and
an information quantity into what the field wants, and `ActivePacketSource`
folds three NED parameters into one `PacketTemplate`. Neither is a shape the
default path can express.

**Every suite, at the end:**

| suite | result | baseline |
| --- | --- | --- |
| `test_queuing()` | 278 passed, 2 errored | 275/2 plus the reset guard's three |
| `test_inet()` | 281 passed | unchanged |
| `test_linklayer()` | 424 passed, 4 errored | unchanged, confirmed on clean main |
| `test_tutorial()` | 188 passed | unchanged |
| `OmnetppDescriptionTest` | 227 passed | unchanged |
| `test_simulator()` | 5914 passed | 5892 plus 22 new tests |

The errors in the two INET suites are all `record_tap!` and its neighbours, and
they predate this work: `omnetpp-julia` main has moved ahead of what this
repository's capture seam expects.

**Two ways to be misled when re-running these.** `test_simulator()` needs
`julia -t 4`; with one thread `engine_startable(ParallelEngineSpec())` fails and
reads as a regression. And `test_tutorial()` hangs off no `test_*` aggregator
and needs the *root* project — `julia --project=. -e 'using InetQueuingExample;
test_tutorial()'`. It was the only suite that caught the submodule path change,
so it is worth running by hand after anything that touches a compound.

## 6. Out of scope

- `InetLinkLayer`. `T1sModel` builds a network by hand too, and it gets its own
  plan, as `queueing-tutorial-from-ned-ini.md` §4 already said.
- The anatomy's `SimulationModule` runtime, §12's model, §17's instance. The
  macro targets the module contract that exists.
- §5's seed at a reference and §16's derivation. Phase 1 keeps today's seeding.
- Making a statistic carry a unit or a recording mode. §28 will want it; nothing
  needs it yet.

## 7. Risks, and which of them came true

- **A macro that generates a struct is hard to read when it is wrong.** It never
  was, but only because the messages were written first. What actually cost
  time was a different kind of wrongness: generated code that resolves a bare
  name in the caller's module. Phase 0's notes say what that looks like.
- **`reset_module!` becomes generated, and a hand-written one may have done
  more.** *This one came true*, in the mildest form and in the opposite
  direction. The generated reset does **more**, not less: it writes the
  recording handle back where the hand-written one left it alone. Safe, because
  a run registers again, but safe by an ordering. A test pins it now. Diffing
  each reset before deleting it is what found this.
- **A `const` field in a mutable struct changes the struct's layout rules.**
  Did not bite. Every parameter field is `const`, and every suite is at its
  baseline. §4 has the answer.
- **The statistics seam must not become a way to read a statistic from
  behaviour.** Still true, and now easier to check than it was: every statistic
  is a declared field of a known kind, so `collect_module_statistics` says
  exactly what no behaviour may read.

**One risk this plan did not list, and should have.** A transformer that passes
over a call site in silence is worse than one that refuses it. The tool stayed
quiet on `PacketMultiplexerModule(:mux, 2)` — a ported element with no parameter
struct to dissolve — and the call would have broken at run time with nothing
said. Wave 5 found it, by nearly falling into it. Anything that rewrites in bulk
needs a rule for *what it deliberately did not touch*, not only for what it
changed.
