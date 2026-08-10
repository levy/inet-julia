# Architecture — the packages, and what belongs in each

`inet-julia` is the network-model library above the `omnetpp-julia` simulation
kernel: the packet representation and the protocol models you build networks
*with*. This document is the map — which package owns what, how they depend on
each other, and how the environments are arranged.

The **kinds** of package (main, example, test, repl), what each may depend on,
and why `InetRepl` is the only thing the `ji` alias loads, are in
[packages.md](packages.md).

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
| `inet/` | `Inet` | the umbrella: re-exports, `inet_simulation_catalog`, the packet diagram | all of the above, `ProjecturedVisual` |
| `runner/` | `InetRunner` | the command line, the run, the result files — what the `inet-julia` executable is built from | `InetQueuing`, `OmnetppSimulator` |
| `repl/` | `InetRepl` | the leaf the `ji` alias loads; nothing may depend on it | `Inet`, `InetExample`, `InetTest`, `ProjecturedSdl` |

```
InetPacket ──┬─────────────► InetQueuing ──┬──────────────► Inet
             └─────────────► InetLinkLayer ┘
InetCommon ────────────────► InetQueuing ─────────────────► InetRunner
```

`InetLinkLayer` does not depend on `InetQueuing` today — the 10BASE-T1S port
predates the element library. The modular Ethernet models will add that edge;
the graph stays acyclic either way.

`InetRunner` and `Inet` are two leaves over the same library, and neither
depends on the other. The umbrella carries the editor stack for the packet
diagram; the runner must not, because it is shipped as an executable and a
runner draws nothing. That rule is checked, not stated — see below.

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
- **`inet`** — only what needs every component at once, or a component and the
  editor stack together. Today that is `inet_simulation_catalog`, which extends
  the kernel's catalog with every model this library provides; the re-exports
  that keep `using Inet` reaching everything; and the **packet diagram**
  (`packetdiagram/`), which draws a packet as the ASCII art figure the RFCs use
  and so needs `InetPacket` and `ProjecturedVisual` at once. It is the one
  reason the umbrella depends on the editor stack, and the reason a headless
  run of `using Inet` loads it; a split into its own package is the answer if
  that cost ever bites. See [packet-diagram.md](../package/inet/doc/packet-diagram.md).
- **`runner`** — one simulation, from a command line, to a pair of result
  files. It earns a package on both counts at once: its consumer is a command
  line and not a Julia caller, and its `Project.toml` is a **contract** rather
  than a convenience. The editor must not be reachable from it —
  `ProjecturedVisual`, `ProjecturedDomain`, the `Projectured` umbrella,
  `OmnetppLegacy`, `DataFrames` and `Revise` are all forbidden, because
  `tool/build_binary.jl` compiles this closure into an executable a user
  installs. `InetRunnerTest.test_runner_closure()` walks `[deps]` through
  `[sources]` and asserts it. See
  [native-simulation-binary.md](../plan/done/native-simulation-binary.md).

  The build takes parameters. `tool/Build.jl` is the builder and
  `tool/build_binary.jl` is a front end over it: the name, how much the build
  compiles ahead of time, and which processor the image is for. They reach the
  program as preferences, and `--build-info` prints them back. A second
  executable that also draws is planned in
  [executable-with-user-interface.md](../plan/pending/executable-with-user-interface.md);
  `-u Editor` is already a name the command line reads and this build refuses.

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
| the command line + the runner | `julia --project=package/runner/test -e 'using InetRunnerTest; test_runner()'` |
| the executable's closure alone | `julia --project=package/runner/test -e 'using InetRunnerTest; test_runner_closure()'` |

Each test package exposes one named function so the suite is callable from a
REPL, and keeps the `runtests.jl` that `Pkg.test` conventions expect. The
repository-wide `test/runtests.jl` is just the five calls in one testset.

`test_runner_closure()` is worth running alone. It is a static walk of `[deps]`
and `[sources]`, it needs nothing instantiated, and it is the only thing that
keeps the editor out of the shipped executable.

`InetCommon` has no test package: its lookup mechanism is covered by phase 0 of
the queuing suite, which is written against the packet-protocol interfaces and
so belongs on that side of the dependency edge. It earns its own suite when
something tests lookup without them.
