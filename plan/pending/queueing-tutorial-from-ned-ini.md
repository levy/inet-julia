# Run the INET queueing tutorial from its own NED and INI files

**Status:** design, not started (2026-08-07).
**Goal:** run all 49 configurations of `inet-cpp/tutorials/queueing` on the
Julia simulator, from the original `QueueingTutorial.ned` and `omnetpp.ini`,
without a change to either file.
**Depends on:** `omnetpp-julia/plan/pending/ned-ini-to-anatomy.md`. That plan
builds the readers and the anatomy layers. Read it first. Nothing here restates
it.
**Does not replace:** [plan/done/queuing-tutorial-migration.md](../done/queuing-tutorial-migration.md).
That tutorial is a navigable document in which the Julia form is the model. It
stays as it is. This plan adds a second path to the same simulations.

---

## 1. Goal

The queueing tutorial of INET is 49 simulations. Each one is a `network` in one
NED file and a `[Config …]` in one INI file. Together they use 49 element types
and most of the NED language.

Run every one of them here, from those two files. That proves three things at
once:

- The readers of the companion plan work on a real file and not on a sample.
- The Julia element library covers a real slice of INET.
- A Julia result can be compared against a C++ result, simulation by
  simulation.

The two files are the input. Copy them into this repository under
`package/queuing/example/tutorial-ned/`, byte for byte, and record the
`inet-cpp` commit that they came from. Do not edit them. An edit would make the
comparison meaningless.

## 2. What this repository has today

`InetQueuing` holds about 20 element kinds. It has no NED, no INI, and no NED
type names. An element is a Julia struct with a `Parameters` struct beside it,
and a model builds a `Network` by hand with `add_module!` and `connect!`.

`InetPacket` holds the packet and chunk model, the tags and the region tags.
`InetCommon` holds the interface lookup that replaces INET's protocol
registration.

### What upstream has, so this plan does not invent a third path

`omnetpp-julia` settled the question of what a NED-built network *is*
(`plan/done/ned-models-are-models.md`): **a built `Network` is a model.**
`NetworkModel` implements the engine's four questions over a module tree, so a
network read out of NED is instantiated, prepared, run, held, stepped and
watched by the same pipeline a hand-written model is. Registering one is two
calls — `register_network_model!(name; build, space, description, statistics)`
and `network_model_type(name)` — where `build` wires a tree from resolved
parameters and must be repeatable, because a reset is a fresh tree.
`OmnetppTictoc`'s `Catalog.jl` is eight lines of exactly that, and
`documentation/model-migration.md` §5.6 is the written procedure.

There is also `OmnetppRunner`'s `ned_network_model(; ini_path, config,
ned_directories, run_number)` — the same registration with the paths as
arguments instead of as constants. Its own docstring says it belongs one layer
down, in `OmnetppDescription`, once a second caller has proved the shape. **This
plan is that second caller.** Use it, and if it fits, move it down rather than
copying it.

**Land on that.** A migration that ends in a network only `run_network!` can
drive is not finished — it has no execution to start, hold, step or watch, so
nothing in the editor can show it.

`run_network!` itself is unchanged and is not going away: this repository's 54
call sites keep working. It is now the one-call shorthand over that same
pipeline rather than a second way of running a network, so a run started here
and a run started from a window are the same run.

## 3. The element inventory

The tutorial names 49 concrete types and 6 contract interfaces. The table
counts what exists.

| INET package | type | state |
| --- | --- | --- |
| `queueing.source` | `ActivePacketSource` | exists |
| | `PassivePacketSource` | exists |
| | `EmptyPacketSource` | missing |
| | `QueueFiller` | missing |
| | `ResponseProducer` | missing |
| `queueing.sink` | `ActivePacketSink` | exists |
| | `PassivePacketSink` | exists |
| | `RequestConsumer` | missing |
| `queueing.queue` | `PacketQueue` | exists |
| | `DropTailQueue` | exists as a preset, needs its own name |
| | `PriorityQueue` | exists |
| | `CompoundPacketQueueBase` | missing |
| `queueing.buffer` | `PacketBuffer` | missing |
| | `PriorityBuffer` | missing |
| `queueing.classifier` | `PacketClassifier` | exists |
| | `PriorityClassifier` | exists |
| | `WrrClassifier` | exists |
| | `ContentBasedClassifier` | exists |
| | `MarkovClassifier` | exists |
| | `LabelClassifier` | missing |
| `queueing.scheduler` | `PacketScheduler` | exists |
| | `PriorityScheduler` | exists |
| | `WrrScheduler` | exists |
| | `ContentBasedScheduler` | exists |
| | `MarkovScheduler` | exists |
| `queueing.server` | `PacketServer` | exists |
| | `InstantServer` | exists |
| | `TokenBasedServer` | missing |
| `queueing.filter` | `ContentBasedFilter` | exists as `PacketFilterModule` |
| | `OrdinalBasedDropper` | missing |
| | `RedDropper` | missing |
| | `StatisticalRateLimiter` | missing |
| `queueing.gate` | `PacketGate` | missing |
| `queueing.marker` | `PacketTagger` | missing |
| | `ContentBasedTagger` | missing |
| | `ContentBasedLabeler` | partial, `PacketLabelerModule` |
| `queueing.meter` | `ExponentialRateMeter` | missing |
| `queueing.shaper` | `LeakyBucket` | missing |
| | `TokenBucket` | missing |
| `queueing.tokengenerator` | `TimeBasedTokenGenerator` | missing |
| | `PacketBasedTokenGenerator` | missing |
| | `QueueBasedTokenGenerator` | missing |
| | `SignalBasedTokenGenerator` | missing |
| `queueing.common` | `PacketMultiplexer` | exists |
| | `PacketDemultiplexer` | exists |
| | `PacketDelayer` | exists |
| | `PacketCloner` | exists |
| | `PacketDuplicator` | exists |
| | `OrdinalBasedDuplicator` | missing |
| `protocolelement.transceiver` | `PacketTransmitter` | missing |
| | `PacketReceiver` | missing |
| `ned` | `DatarateChannel` | missing |

24 element types are missing, and 2 need work. The contract interfaces
`IActivePacketSource`, `IPassivePacketSource`, `IPassivePacketSink`,
`IPacketServer`, `IPacketClassifier` and `IPacketScheduler` become abstract
Julia types, because a `like` submodule field declares one of them.

Five policies come in as a class name in a string, and each needs an entry in a
registry:

- `inet::queueing::PacketDataComparator`
- `inet::queueing::PacketAtCollectionBeginDropper`
- `inet::queueing::PacketDataClassifier`
- `inet::queueing::PacketDataScheduler`
- `inet::queueing::PacketCharacterOrEnterClassifier`

## 4. Two decisions to settle first

The third — whether to migrate the elements onto the anatomy module form — is
settled and done. `queuing-elements-on-the-module-macro.md` carried it out: all
sixteen simple elements of `InetQueuing` declare their fields by kind, and no
`Parameters`, `States` or `Statistics` struct is left in the package. The
compound is what remains there, not here. `InetLinkLayer` still builds a
`Network` by hand and still needs its own plan.

### 4.2 Give the chunk a fill byte

The tutorial writes `expr(ByteCountChunk.data == 0)` and
`*.producer.packetData = intuniform(0, 255)`. INET's `ByteCountChunk` carries a
fill byte in a field called `data`, and the expression reads that field.

This repository has `Filler`, which is length-only, and it carries the value in
a `DataTag` instead. An expression that names `ByteCountChunk.data` would then
read something that is not a chunk field.

**Add the fill byte to `Filler`.** The name in the expression then means what it
means in INET. Keep `DataTag`, because other code uses it.

The alternative is a translation table in the expression evaluator, from
`ByteCountChunk.data` to the tag. Reject it. It hides a mismatch that a reader
of the tutorial would have to know about.

### 4.3 Set the bar for a result comparison

Three levels are possible, and they cost very different amounts.

**Level 1, structure.** The tree that the reader builds matches the NED. Every
submodule name, every submodule kind and every connection. Free, and it catches
most reader faults.

**Level 2, statistics.** The counts and the rates of a Julia run agree with a
C++ run of the same config, inside a tolerance. This is the bar for every
config.

**Level 3, exact.** The same numbers as `opp_run`. This costs much more than it
looks, for two reasons that have nothing to do with the elements.

- OMNeT++ maps every module to random number generator 0 by default. So all the
  draws of a whole network come off one stream, in the order that the events
  run. §5 of the anatomy gives each module a stream of its own. Level 3 needs a
  compatibility mode with one shared stream.
- The order of the draws must match as well, and that follows from the event
  order, not from the model.

**Take Level 1 and Level 2 as the bar.** Try Level 3 on the first two configs
only, where the network is a source and a sink and the draw order is obvious.
If it works there, the compatibility mode is real and a later plan can widen
it.

One divergence blocks Level 3 today, and it is worth fixing anyway.
`OmnetppSimulator.VolatileModule` draws an exponential as
`-mean * log(max(rand(rng), 1e-12))`. OMNeT++ draws from an open interval
instead. Fix the Julia side to match, and note it in the companion plan.

## 5. Produce the C++ reference results

`inet-cpp` is built. `out/clang-release/src/libINET.so` and
`out/clang-debug/src/libINET_dbg.so` both exist.

1. Source the `setenv` of the OMNeT++ installation, then the `setenv` of
   `inet-cpp`.
2. Run one config:
   `cd inet-cpp/tutorials/queueing && ../../bin/inet -u Cmdenv -c <Config>`.
3. Collect `results/<Config>-#0.sca` and `results/<Config>-#0.vec`.

Write `tool/reference-results.sh` to run all 49 and copy the output into
`package/queuing/test/inet-reference/queueing/`. Commit the results. They are
small, they are the ground truth, and a reader of a failure must not need a C++
build to see what the number should be.

`OmnetppLegacy` already reads `.sca` and `.vec` into DataFrames. Use it in the
comparison, so that nothing new parses a result file.

## 6. Waves

Each wave ends with configs that run. The order is the tutorial's own order,
from `doc/index.rst`. Work in a worktree at
`/home/projectured/workspace/inet-julia-tutorial-ned`. It must be a sibling of
`inet-julia`, or the relative `[sources]` break. Commit at each wave, and mark
the wave done here.

| wave | tutorial group | configs | new element types |
| --- | --- | --- | --- |
| 0 | the seam | — | the registry, the contract abstract types |
| 1 | sources and sinks | 1–2 | — |
| 2 | queues and buffers | 3–6 | `DropTailQueue` name, `PacketBuffer` |
| 3 | classifiers | 7–11 | — |
| 4 | schedulers | 12–16 | — |
| 5 | advanced queues and buffers | 17–19 | `PriorityBuffer`, `CompoundPacketQueueBase` |
| 6 | filters and droppers | 20–23 | `OrdinalBasedDropper`, `RedDropper` |
| 7 | servers | 24–25 | `TokenBasedServer` |
| 8 | token generators | 26–29 | the four token generators |
| 9 | markers and meters | 30–33 | `ExponentialRateMeter`, `StatisticalRateLimiter`, `PacketTagger`, `ContentBasedTagger`, `LabelClassifier` |
| 10 | traffic conditioning | 34–35 | `LeakyBucket`, `TokenBucket` |
| 11 | generic elements | 36–43 | `PacketGate`, `OrdinalBasedDuplicator` |
| 12 | advanced sources and sinks | 44–45 | `QueueFiller`, `RequestConsumer`, `ResponseProducer` |
| 13 | complex examples | 46–49 | `EmptyPacketSource`, `PacketTransmitter`, `PacketReceiver`, `DatarateChannel` |

### Wave 0 — The seam

1. Add a dependency on `OmnetppDescription` to `InetQueuing`.
2. Migrate the queuing elements onto the anatomy module form. Done: see
   `queuing-elements-on-the-module-macro.md`.
3. Migrate `QueuingModel` and the demo models under `example/steps/`.
4. Register every element under its NED type name, such as
   `inet.queueing.queue.PacketQueue`.
5. Declare the six contract interfaces as abstract types, and make each element
   a subtype of the ones it satisfies.
6. Register the five policy classes of §3 by their C++ name.
7. Give the expression evaluator the names it needs: `totalLength`,
   `ByteCountChunk.data`, and the packet itself.
8. Add the fill byte to `Filler`, per §4.2.

Check: read `QueueingTutorial.ned` and assert, for each of the 49 networks,
that every submodule kind resolves. A kind that is still missing must fail with
its NED type name, not with a `nothing`.

### Wave 1 to wave 13

Each wave repeats the same four steps.

1. Write the element types of the wave. Port each one from its INET `.ned` file
   and its `.cc` file. The `.ned` file gives the parameters, their defaults and
   their units. The `.cc` file gives the behaviour.
2. Run each config of the wave from the two original files.
3. Assert Level 1 for each config, against the table of wave 0.
4. Assert Level 2 for each config, against the reference results of §5.

Two waves carry a risk that the others do not.

**Wave 5** needs `CompoundPacketQueueBase`, and the tutorial extends it. That
is the only `extends` in the file, and §3.8 of the companion plan settles what
`extends` means. Do not start wave 5 before that is settled.

**Wave 13** needs the most. `TelnetTutorialStep` is the only user of `like`
submodules and of the `<--` connection. `ExampleNetworkTutorialStep` nests
three compounds. `InputQueueSwitching` and `OutputQueueSwitching` need module
vectors, inline channels, a named `DatarateChannel`, and the transmitter and
receiver pair. A transmitter sends a packet over time, and that is §9 of the
anatomy, which the companion plan leaves out of scope. Wave 13 must either
bring §9 in or model a transmission as a delay. Decide when wave 13 starts, and
record the decision here.

## 7. Where the code goes

- `package/queuing/main/` — every element type, in the folder of its INET
  package. Follow [plan/pending/folder-layout-alignment.md](folder-layout-alignment.md):
  a compound goes to `compound/`, and `common/` splits.
- `package/queuing/example/tutorial-ned/` — the two original files, byte for
  byte, and a `SOURCE.md` that records the `inet-cpp` commit.
- `package/queuing/test/inet-reference/queueing/` — the C++ reference results.
- `package/queuing/test/phase6_tutorial_ned.jl` — the Level 1 and Level 2
  assertions, one test set for each wave.

The existing tutorial under `package/queuing/example/tutorial/` does not move
and does not change, except where wave 0 migrates the models under it.

## 8. Tests

```
julia --project=package/queuing/test -e 'using InetQueuingTest; test_queuing()'
julia --project=. test/runtests.jl
```

Cap the memory of a full run. A 1000 second config with three sources produces
many events, and configs 48 and 49 are the two that can take the machine down.

Only the `Fail` and `Error` counts matter. The method overwrite warnings from
the phase files are expected.

## 9. Out of scope

- Every INET element that this tutorial does not use. The queueing package of
  INET holds about 100 elements, and 49 of them appear here.
- The TSN gates, the flow measurement and the PCAP elements of
  [plan/pending/queuing-model-migration.md](queuing-model-migration.md).
- `InetLinkLayer`. Wave 0 migrates the queuing elements only. The 10BASE-T1S
  model needs its own plan for the same migration.
- A NED file or an INI file on screen in the editor as a running network. The
  editor already opens both as documents.
