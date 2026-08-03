# Inet

The network-model library above the `omnetpp-julia` simulation kernel: INET's
packet representation, queuing elements and protocol models, in Julia.

## Before working here

Read [README.md](README.md) for what the library is, and
[documentation/architecture.md](documentation/architecture.md) for the package
graph and the rule for where new material belongs. Per-component references live
in `package/<component>/doc/`.

## Layout

Five packages under `package/<component>/`, each `{main, test, example, doc}`:
`packet` (`InetPacket`), `common` (`InetCommon`), `queuing` (`InetQueuing`),
`linklayer` (`InetLinkLayer`) and `inet` (`Inet`, the umbrella). The repository
root is a development **environment**, not a package.

Nothing else belongs at the top level: a component's code, tests, examples,
tooling and reference guide all live inside its folder. Cross-cutting guides go
in `documentation/`, plans in `plan/`.

New material goes into the **lowest** package where it makes sense. A package is
earned by a genuinely different dependency or consumer set — it costs a
`Project.toml`, a UUID and a `[sources]` entry in everything downstream; a new
protocol is a slice inside `linklayer`, not a package.

`InetPacket` depends on **nothing** — not the simulator, not the ProjecturEd
kernel. Keep it that way: that rule is what its separate package is for.

## Testing a change

Run the **smallest suite that covers the change**, not the aggregator:

| what changed | command |
|---|---|
| the packet API | `julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'` |
| queuing elements, lookup | `julia --project=package/queuing/test -e 'using InetQueuingTest; test_queuing()'` |
| 10BASE-T1S / PLCA | `julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'` |
| the catalog / re-exports | `julia --project=package/inet/test -e 'using InetTest; test_inet()'` |
| a cross-component change | `julia --project=. test/runtests.jl` |

Only `Fail` and `Error` counts matter; the `Method definition … overwritten`
warnings from the phase files sharing helper names are expected.

## Worktrees

The `[sources]` reach `omnetpp-julia` and `projectured-julia` by relative path,
so a git worktree **must be created as a sibling** of `inet-julia` (in
`/home/projectured/workspace/`), never inside the checkout — otherwise every
path dependency breaks. `Manifest.toml` is gitignored; run `Pkg.instantiate()`
in a fresh worktree.
