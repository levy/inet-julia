# Packages

What a package here is for, what it may depend on, and which one you load.
[architecture.md](architecture.md) says which package owns what; this document
says the shape they are arranged in, which is the same shape in all three
repositories.

## The five kinds

Every stem has up to five packages, and the suffix says which kind it is:

| kind | name | what it holds |
| --- | --- | --- |
| main | `Stem` | the code |
| example | `StemExample` | documents, galleries, and the workload **bodies** |
| test | `StemTest` | the suite |
| repl | `StemRepl` | the leaf a person loads to work |
| build | `StemBuild` | the leaf a binary is compiled from |

`Example`, `Test`, `Repl` and `Build` are the only reserved suffixes; `doc/`
holds a reference guide and is not a package.

## One dependency direction

```
Foo         -> Bar, and every sub-stem of Foo
FooExample  -> Foo,  BarExample
FooTest     -> Foo,  BarTest, FooExample
FooRepl     -> InetTest and what a prompt wants                 (leaf)
```

**Nothing may depend on `InetRepl`.** That is the whole mechanism, and the next
section says why.

## Why the leaf matters

A package image is built with exactly that package's dependencies present. So
compiled code survives only in a package that nothing depends on and nothing
loads after — the leaf the alias loads. Everything below it has its compiled
code **invalidated** when the session finishes loading, because a method added
later can void a call site that was already compiled.

Measured in omnetpp-julia, where the effect is largest: loading its umbrella and
its example and test packages voided 15286 method instances, and the first click
on a catalog page cost 5.98 s of which 3.88 s was recompilation. With a workload
in the leaf it costs 0.21 s.

That is why `@compile_workload` lives only in `InetRepl`, and why the body it
calls — `InetExample.precompile_workload(level)` — is an ordinary function.

## The session

```bash
ji   # julia --project=. -i -e 'using Revise, InetRepl'
```

`InetRepl` re-exports what it names, so one `using` gives the session you expect.
Revise stays in the alias and out of the package's dependencies: it must be
loaded before the packages it tracks. **Nothing may be loaded after the leaf.**

How much the build compiles is a Preference, so changing it rebuilds:

```julia
julia> get_workload()          # what this session was built with
julia> set_workload!(:demo)    # then restart
```

`:minimal` redoes `ProjecturedExample`'s workload in this image — not
duplication, since a workload can only cache inference that is still valid once
the session has finished loading. `:demo` adds this repository's own catalog
page, which no atom reaches: an atom is one node type, a page is the whole chain
over a file. Measured at `:demo`, the catalog's first paint is 0.162 s with no
recompilation.

## What depends on what

| package | depends on | third-party |
| --- | --- | --- |
| `InetPacket` | — | — |
| `InetCommon` | OmnetppSimulator, ProjecturedKernel | — |
| `InetLinkLayer` | Packet, OmnetppSimulator, ProjecturedKernel | — |
| `InetQueuing` | Common, Packet, OmnetppSimulator, ProjecturedKernel | — |
| `InetRunner` | Packet, Queuing, OmnetppDescription, OmnetppFormat, OmnetppSimulator, OmnetppUnits | — |
| `Inet` (umbrella) | Common, LinkLayer, Packet, Queuing, OmnetppSimulator, ProjecturedVisual | — |
| `<Stem>Example` | `<Stem>`, the Examples below it | — |
| `<Stem>Test` | `<Stem>`, `<Stem>Example`, the Tests below it | — |
| `InetRepl` **(leaf)** | Inet, InetExample, InetTest, ProjecturedSdl | PrecompileTools, Preferences |

**No package in this repository holds a third-party dependency**, and none
should acquire one without being named here with its reason. That is worth
keeping: in omnetpp-julia, DataFrames and CairoMakie between them accounted for
most of 15286 invalidated method instances, and getting them out of a session
took two package moves.

`[sources]` here reach the **main** checkouts of projectured-julia and
omnetpp-julia, so a change in one of those is invisible until it lands there.

## Adding a package

1. Decide whether it is a **sub-stem** (a layer, no third-party dependency) or a
   **stem of its own** (it has one). Only the first may be aggregated.
2. Give it the kinds it needs, with the reserved suffixes.
3. Name every third-party dependency in the table above, with its reason.
4. Do not depend on a leaf, and do not put a `@compile_workload` outside one.
