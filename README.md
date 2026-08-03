# Inet — network model library (Julia)

## Overview

`Inet` is the network-model library for [`omnetpp-julia`](../omnetpp-julia) —
a Julia reimplementation of INET's packet representation and protocol models.
The split mirrors the C++ world: `OmnetppSimulator` is the discrete-event kernel
(the engine, the simulation lifecycle, result recording), and `Inet` is what you
model networks *with*.

The dependency runs one way only: `Inet` uses `OmnetppSimulator`, never the
reverse.

Three things live here today:

- **the packet & chunk API** — a representation-independent packet data model,
  derived from INET's `Chunk`/`Packet` API but redesigned around Julia's type
  system. A 1500-byte payload nobody inspects costs one integer; ask for a
  header type and you get one whether the packet currently holds a field
  struct, raw bytes, or just a length.
- **the queuing elements** — INET's `queueing` package: sources and sinks,
  queues, servers, classifiers, schedulers, filters and the plumbing between
  them, moving packets by direct push/pull calls with backpressure, and finding
  each other by module lookup rather than registration.
- **10BASE-T1S with PLCA** — INET's multidrop Ethernet model (IEEE
  802.3cg-2019): four FSMs (MAC, PLCA control, PLCA data, PHY) over a
  first-class wire junction, plugged into the lifecycle as a model.

## Project layout

Five Julia packages under `package/<component>/`, each `{main, test, example,
doc}` — see [documentation/architecture.md](documentation/architecture.md) for
the package graph, the rule for where new material belongs, and the environment
model.

| component | package | owns |
|---|---|---|
| `packet` | `InetPacket` | the packet & chunk API (`PacketModule`). Depends on nothing — not the simulator, not the ProjecturEd kernel |
| `common` | `InetCommon` | module-interface lookup (`LookupModule`): finding the module that offers an interface, by connection or by reference |
| `queuing` | `InetQueuing` | the packet protocol, the queuing elements, and `QueuingModel` |
| `linklayer` | `InetLinkLayer` | 10BASE-T1S / PLCA (`T1sModule`) and `T1sModel`, the wrapper that runs it |
| `inet` | `Inet` | the umbrella: re-exports every component's modules, owns `inet_simulation_catalog` |

Outside `package/`:

- `documentation/` — cross-cutting guides; per-component references live in
  `package/<component>/doc/`.
- `plan/` — design + implementation plans (`pending/`, `done/`).
- `test/runtests.jl` — the repository-wide aggregator over the test packages.

The repository root is a development **environment**, not a package, so
`julia --project=.` resolves every component at once.

## Getting started

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/runtests.jl
julia --project=package/packet/example package/packet/example/packet_api_demo.jl
```

To run one component's suite instead — each environment resolves standalone, so
the packet suite needs no simulator at all:

```bash
julia --project=package/packet/test    -e 'using InetPacketTest;    test_packet()'
julia --project=package/queuing/test   -e 'using InetQueuingTest;   test_queuing()'
julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'
julia --project=package/inet/test      -e 'using InetTest;          test_inet()'
```

The `[sources]` reach `OmnetppSimulator` and the ProjecturEd packages by
relative path, so `omnetpp-julia` and `projectured-julia` must sit next to this
checkout.

## Using it

`Inet` re-exports nothing from `OmnetppSimulator` — a script that needs both
says so, which keeps it visible which layer a name comes from:

```julia
using OmnetppSimulator, Inet

t = SimulationType(T1sModel)                       # the model, from Inet
a = ParameterAssignment(Dict{Symbol,Any}(          # the lifecycle, from OmnetppSimulator
    :n_nodes    => 5,
    :time_limit => 100e-6,
    :scenario   => :notraffic))
run  = expand_simulation(configure_simulation(t, a))[1]
inst = prepare_simulation_execution(run; engine = SequentialEngineSpec())
run_simulation!(inst)
res  = finish_simulation!(inst)
```

To offer `Inet`'s models in a workbench, hand it the extended catalog:

```julia
SimulationWorkbench(; catalog = inet_simulation_catalog())
```

The packet API is a submodule and exports a lot of short names, so it is
imported explicitly — through the umbrella, or straight from its own package:

```julia
using Inet.PacketModule          # or: using InetPacket.PacketModule

pk = Packet(Filler(Bytes(1500)))     # 1500 bytes of payload, stored as a length
data_length(pk)                      # 1500B
peek(pk, Raw; length = Bytes(4))     # materialise only what you look at
```

## Read next

1. [documentation/architecture.md](documentation/architecture.md) — the package
   graph, where new material belongs, and how the environments are arranged.
2. [package/packet/doc/packet.md](package/packet/doc/packet.md) — the packet &
   chunk API: the two layers, the representations, `peek`, quality, tags,
   buffers.
3. [package/linklayer/doc/ten-base-t1s.md](package/linklayer/doc/ten-base-t1s.md)
   — the four FSMs, the wire model, and the non-obvious design decisions behind
   them.
4. `plan/done/` — the design documents the code was built from, including the
   requirement-by-requirement derivation from INET's own sources.
