# Architecture — the packages, and what belongs in each

`inet-julia` is the network-model library above the `omnetpp-julia` simulation
kernel: the packet representation and the protocol models you build networks
*with*. This document is the map — which package owns what, how they depend on
each other, and how the environments are arranged.

## The packages

Every component is a Julia package under `package/<component>/`, and every
component folder holds up to four sibling packages of equal standing:
`main/` (the code), `test/` (its suite), `example/` (its runnable
demonstrations) and `doc/` (its reference guide). The component folder itself
has no project file — a Julia package is defined by its `Project.toml`, not by
where its directory sits. A component grows a `test/`, `example/` or `doc/`
when it earns one.

| folder | package | owns | depends on |
|---|---|---|---|
| `packet/` | `InetPacket` | chunks, packets, headers, quality, tags, buffers, `peek` | *nothing* |
| `common/` | `InetCommon` | module-interface lookup (`LookupModule`) | `OmnetppSimulator`, `ProjecturedKernel` |
| `queuing/` | `InetQueuing` | the packet protocol, the queuing elements, `QueuingModel` | `InetPacket`, `InetCommon` |
| `linklayer/` | `InetLinkLayer` | 10BASE-T1S / PLCA and `T1sModel` | `InetPacket` |
| `inet/` | `Inet` | the umbrella: re-exports, `inet_simulation_catalog` | all of the above |

```
InetPacket ──┬─────────────► InetQueuing ──┐
             └─────────────► InetLinkLayer ┼──► Inet
InetCommon ────────────────► InetQueuing ──┘
```

`InetLinkLayer` does not depend on `InetQueuing` today — the 10BASE-T1S port
predates the element library. The modular Ethernet models will add that edge;
the graph stays acyclic either way.

## Where a thing belongs

- **`packet`** — the data model of what travels. Its rule is that it depends on
  nothing: not the simulator, not the ProjecturEd kernel. Anything that needs
  to know a simulation exists is not packet material.
- **`common`** — infrastructure every model library above it shares, INET's
  `src/inet/common` in spirit. Lookup lives here because it is deliberately
  independent of what is being looked up: putting it in `queuing` would force a
  `linklayer → queuing` edge the day a protocol model needs to find a peer.
  `StatisticsModule` is the first candidate to sink here, once something that
  is not a queuing element records anything.
- **`queuing`** — INET's `queueing` package, spelled the standard way: the four
  roles a module plays at a gate, and the elements that play them.
- **`linklayer`** — the protocol models. Named after the INET tree it will grow
  into rather than after its single current occupant; a protocol brings its own
  `AbstractModel` wrapper with it (`t1s/T1sModel.jl`).
- **`inet`** — only what needs every component at once. Today that is
  `inet_simulation_catalog`, which extends the kernel's catalog with every model
  this library provides, and the re-exports that keep `using Inet` reaching
  everything.

New material goes into the *lowest* package where it makes sense. A second
protocol is a slice inside `linklayer`, not a package of its own; a package is
earned by a genuinely different dependency set or consumer set, because it costs
a `Project.toml`, a UUID and a `[sources]` entry in everything downstream.

## Environments

The repository root is a development **environment**, not a package: `julia
--project=.` resolves every component plus `OmnetppSimulator` and
`ProjecturedKernel`, so a cross-component change is one REPL.

Each package also carries its own `[sources]`, so its environment can be
activated standalone — which is how the packet suite runs in an environment
with no simulator in it at all. When working from the root, the root's
`[sources]` win.

Those `[sources]` reach the sibling repositories by **relative path**
(`../../../../omnetpp-julia/package/simulator/main`), so `omnetpp-julia` and
`projectured-julia` must sit next to this checkout — and a git worktree must be
created as a *sibling* of `inet-julia`, not inside it, or every path dependency
breaks.

`Manifest.toml` is gitignored: every environment resolves its own.

## Testing

| what | command |
|---|---|
| everything | `julia --project=. test/runtests.jl` |
| the packet API | `julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'` |
| the queuing elements + lookup | `julia --project=package/queuing/test -e 'using InetQueuingTest; test_queuing()'` |
| 10BASE-T1S / PLCA | `julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'` |
| the umbrella (catalog) | `julia --project=package/inet/test -e 'using InetTest; test_inet()'` |

Each test package exposes one named function so the suite is callable from a
REPL, and keeps the `runtests.jl` that `Pkg.test` conventions expect. The
repository-wide `test/runtests.jl` is just the four calls in one testset.

`InetCommon` has no test package: its lookup mechanism is covered by phase 0 of
the queuing suite, which is written against the packet-protocol interfaces and
so belongs on that side of the dependency edge. It earns its own suite when
something tests lookup without them.
