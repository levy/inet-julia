# Inet — network model library (Julia)

## Overview

`Inet` is the network-model library for [`omnetpp-julia`](../omnetpp-julia) —
a Julia reimplementation of INET's packet representation and protocol models.
The split mirrors the C++ world: `Omnetpp` is the discrete-event kernel (the
engine, the simulation lifecycle, result recording), and `Inet` is what you
model networks *with*.

The dependency runs one way only: `Inet` uses `Omnetpp`, never the reverse.

Two things live here today:

- **the packet & chunk API** — a representation-independent packet data model,
  derived from INET's `Chunk`/`Packet` API but redesigned around Julia's type
  system. A 1500-byte payload nobody inspects costs one integer; ask for a
  header type and you get one whether the packet currently holds a field
  struct, raw bytes, or just a length.
- **10BASE-T1S with PLCA** — INET's multidrop Ethernet model (IEEE
  802.3cg-2019): four FSMs (MAC, PLCA control, PLCA data, PHY) over a
  first-class wire junction, plugged into the `Omnetpp` lifecycle as a model.

## Project layout

This repository is the `Inet` Julia package:

- `src/` — the package, wired together from `Inet.jl`:
  - `packet/` — the packet & chunk API (`Inet.PacketModule`). Depends on
    neither `Omnetpp` nor the rest of `Inet`, so it is usable on its own.
  - `t1s/` — the 10BASE-T1S/PLCA building blocks (`Inet.T1sModule`): Ethernet
    frame chunks, the wire and its junctions, and the four FSMs.
  - `model/` — `T1sModel.jl`, the `AbstractModel` wrapper that plugs
    `T1sModule` into the simulation lifecycle, and `Catalog.jl`.
- `test/` — the phased conformance suites (`Pkg.test()`), ported behaviour by
  behaviour from INET's own unit tests.
- `examples/` — `packet_api_demo.jl`, a worked tour of the packet API. Runs
  under the root project.
- `scripts/` — `compare_t1s_vectors.jl`, which diffs two `.vec` files with
  per-signal tolerance rules tuned for T1S.
- `documentation/` — `packet.md` and `ten-base-t1s.md`.
- `plan/` — design + implementation plans (`pending/`, `done/`).

## Getting started

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'
julia --project=. examples/packet_api_demo.jl
```

`Project.toml` reaches `Omnetpp` and the ProjecturEd packages by relative path,
so `omnetpp-julia` and `projectured-julia` must sit next to this checkout.

## Using it

`Inet` re-exports nothing from `Omnetpp` — a script that needs both says so,
which keeps it visible which layer a name comes from:

```julia
using Omnetpp, Inet

t = SimulationType(T1sModel)                       # the model, from Inet
a = ParameterAssignment(Dict{Symbol,Any}(          # the lifecycle, from Omnetpp
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
imported explicitly:

```julia
using Inet.PacketModule

pk = Packet(Filler(Bytes(1500)))     # 1500 bytes of payload, stored as a length
data_length(pk)                      # 1500B
peek(pk, Raw; length = Bytes(4))     # materialise only what you look at
```

## Read next

1. [documentation/packet.md](documentation/packet.md) — the packet & chunk API:
   the two layers, the representations, `peek`, quality, tags, buffers.
2. [documentation/ten-base-t1s.md](documentation/ten-base-t1s.md) — the four
   FSMs, the wire model, and the non-obvious design decisions behind them.
3. `plan/done/` — the design documents the code was built from, including the
   requirement-by-requirement derivation from INET's own sources.
