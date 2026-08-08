# Inet

The network-model library above the `omnetpp-julia` simulation kernel: INET's
packet representation, queuing elements and protocol models, in Julia.

## 🔒 Sealed files

**Some files in this repository are sealed. Read [SEALING.md](SEALING.md)
before modifying anything: a file marked `🔒` there MUST NOT be modified by an
AI in any way unless the user gives explicit permission for that specific file
in the current conversation.** If a change you are asked to make would require
editing a sealed file, STOP and ask. Files marked `⚙️` are generated — never
hand-edit them; change the machine in the named `tool/` script and regenerate.
`SEALING.md` also holds the audit protocol and the full audit-order inventory;
the campaign that drives it is
[plan/pending/architecture-audit-and-seal.md](plan/pending/architecture-audit-and-seal.md).

## Before working here

Read [README.md](README.md) for what the library is, and
[documentation/architecture.md](documentation/architecture.md) for the package
graph and the rule for where new material belongs.
[documentation/requirements.md](documentation/requirements.md) (`IR-…`) states
what the library promises;
[documentation/architecture-requirements.md](documentation/architecture-requirements.md)
(`IAR-…`) the invariants every change must respect — the substrate's `OAR-…`
and `AR-…` rules bind transitively. Per-component references live in
`package/<component>/doc/`.

## Layout

Six packages under `package/<component>/`, each `{main, test, example, doc}`:
`packet` (`InetPacket`), `common` (`InetCommon`), `queuing` (`InetQueuing`),
`linklayer` (`InetLinkLayer`), `inet` (`Inet`, the umbrella) and `runner`
(`InetRunner`, the command line the `inet-julia` executable is built from). The
repository root is a development **environment**, not a package.

Nothing else belongs at the top level: a component's code, tests, examples,
tooling and reference guide all live inside its folder. Cross-cutting guides go
in `documentation/`, plans in `plan/`.

New material goes into the **lowest** package where it makes sense. A package is
earned by a genuinely different dependency or consumer set — it costs a
`Project.toml`, a UUID and a `[sources]` entry in everything downstream; a new
protocol is a slice inside `linklayer`, not a package.

`InetPacket` depends on **nothing** — not the simulator, not the ProjecturEd
kernel. Keep it that way: that rule is what its separate package is for.

`InetRunner` must not reach the **editor**: no `ProjecturedVisual`, no
`ProjecturedDomain`, no `Projectured` umbrella, no `OmnetppLegacy`, no
`DataFrames`, no `Revise`. `tool/build_binary.jl` compiles that closure into an
executable a user installs, and a runner draws nothing.
`InetRunnerTest.test_runner_closure()` asserts it. Before you add a dependency
there, read
[plan/done/native-simulation-binary.md](plan/done/native-simulation-binary.md) §2.

## Testing a change

Run the **smallest suite that covers the change**, not the aggregator:

| what changed | command |
|---|---|
| the packet API | `julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'` |
| queuing elements, lookup | `julia --project=package/queuing/test -e 'using InetQueuingTest; test_queuing()'` |
| 10BASE-T1S / PLCA | `julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'` |
| the catalog / re-exports | `julia --project=package/inet/test -e 'using InetTest; test_inet()'` |
| the command line, the runner | `julia --project=package/runner/test -e 'using InetRunnerTest; test_runner()'` |
| a dependency of the runner | `julia --project=package/runner/test -e 'using InetRunnerTest; test_runner_closure()'` |
| a cross-component change | `julia --project=. test/runtests.jl` |

Only `Fail` and `Error` counts matter; the `Method definition … overwritten`
warnings from the phase files sharing helper names are expected.

## Worktrees

The `[sources]` reach `omnetpp-julia` and `projectured-julia` by relative path,
so a git worktree **must be created as a sibling** of `inet-julia` (in
`/home/projectured/workspace/`), never inside the checkout — otherwise every
path dependency breaks. `Manifest.toml` is gitignored; run `Pkg.instantiate()`
in a fresh worktree.
