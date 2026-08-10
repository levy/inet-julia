# An executable that holds the editor, and a build that takes parameters

`tool/build_binary.jl` builds one thing. It takes no argument and it writes one
name. This plan turns it into a builder with parameters, and adds a second
binary that holds the ProjecturEd user interface beside the command-line
runner.

The binary that draws is a *superset* of the binary that does not. It holds the
runner, so `-u Cmdenv` writes result files with no window, and `-u Editor`
opens one. The lean binary stays exactly what it is today.

**This plan is the second of a pair.** `omnetpp-julia`'s
`plan/pending/executable-with-user-interface.md` states the design, and this
one repeats it over `InetRunner`. Land that one first: it owns the window, and
two of the steps below wait on seams that it moves.

## 1. Goal

1. **A second binary.** `inet-julia-editor` opens a configuration in a window,
   or opens this repository's demo catalog when the command line names no
   configuration.
2. **A builder with parameters.** The build is a Julia function that takes a
   `BuildSpec`. The command-line front end stays, and reads the same parameters
   as flags.
3. **Outputs a person can tell apart.** The name, the directory, the help text
   and a new `--build-info` option each say which build this is.

The compile workload is one of the parameters, with the same four levels the
repository already uses for a session (`InetRepl.set_workload!`): `:none`,
`:minimal`, `:demo`, `:full`.

## 2. What exists today

| thing | where | state |
| --- | --- | --- |
| the build script | `tool/build_binary.jl` | one fixed configuration, no knob at all |
| what the build traces | `tool/binary_precompile.jl` | the INET corpus and one run, no levels |
| the lean entry package | `package/runner/main` | `InetRunner`, `julia_main`, a dependency contract |
| the guard | `package/runner/test/closure.jl` | a static walk of `[deps]` through `[sources]` |
| the developer wrapper | `bin/inet-julia` | runs the same entry through the checkout |
| the catalog | `InetExample.run_demo`, `demo_catalog`, `demo_projection` | this repository's own demo directory |
| the workload levels | `InetExample.precompile_workload` | `:none`, `:minimal`, `:demo`, `:full` |
| the session knob | `InetRepl.set_workload!` | a preference, read at module scope |

The measured baseline, from `plan/done/native-simulation-binary.md` phase 4:

| number | value |
| --- | --- |
| the bundle | 735 MB |
| `inet-julia --version` | 0.34 s |
| one run, built binary | 0.38 s |
| the same run, `julia --project` | 4.53 s |

The bundle runs under `env -i` with no system Julia and from a copied
directory. Keep that true.

## 3. Two things this repository lacks and the sibling has

### 3.1 There is no model seam

`omnetpp-julia`'s runner has
`ned_network_model(; ini_path, config, ned_directories, run_number)`, which
answers a registered `NetworkModel` **type**. The window takes exactly that
type. `InetRunner.run_options` has no such function: it reads the INI file,
finds the NED file and calls `build_ned_network` inline, and what it holds is a
built network rather than a model the window can reset and re-run.

`omnetpp-julia`'s `plan/done/native-executable-runner.md` §8 already says where
that function belongs — one layer down, in `OmnetppDescription` — and that it
waits for a second caller to prove the shape. **This plan is the second
caller.** So:

- [ ] Promote `ned_network_model` from `OmnetppRunner` into
      `OmnetppDescription` (a change in `omnetpp-julia`).
- [ ] `InetRunner.run_options` builds through it, and answers the same result
      files it answers today.
- [ ] `InetRunnerEditor` hands the same type to the window.

Do not copy the function into this repository. Two copies of a builder that
caches registered models by a hash of its arguments is two caches.

### 3.2 There is no window here

`InetExample` depends on `OmnetppPresentation`, not on
`OmnetppPresentationExample`, and the window
(`run_qtenv_example`, `session_example_document`,
`session_example_projection`) lives in the example package.

Two ways, and the first is the one to take:

1. **Promote the window into `OmnetppPresentation`.** The sibling plan lists
   this as work it does not do, waiting for a second caller. This is that
   caller, and the promotion keeps `InetRunnerEditor`'s dependency list honest.
2. Depend on `OmnetppPresentationExample` from here. It works today, and it
   makes a product binary hold another repository's example package.

The catalog is a different matter. A catalog is example content, and this
repository's catalog is `InetExample`'s. The editor package depends on
`InetExample` for it, and that is not a debt.

## 4. Decisions

Each of these is the sibling plan's decision, applied here. Read that plan for
the reason; this list states only what the name is in this repository.

| # | decision | here |
| --- | --- | --- |
| 3.1 | a second project in the slice, not a new slice | `package/runner/editor`, `InetRunnerEditor` |
| 3.2 | `-u` chooses the interface | `Options.user_interface`, `:cmdenv` or `:editor`; `-u Qtenv` refused, and the refusal names `Editor` |
| 3.3 | the editor binary runs the runner | `InetRunnerEditor.main` branches to `InetRunner.run_options` |
| 3.4 | what the editor opens | a configuration when the command line names one; the catalog when it names none |
| 3.5 | the parameters are baked as preferences | `[InetRunner]` and `[InetRunnerEditor]` in the entry project's `LocalPreferences.toml`, read by `package/runner/main/BuildConfig.jl` and by the editor package |
| 3.6 | the workload reaches both halves | the trace reads `InetRunner.APP_WORKLOAD` |
| 3.7 | one binary, one name, one directory | `build/inet-julia` and `build/inet-julia-editor` |
| 3.8 | `--version` keeps its shape | the parameters go into `--build-info` |

`package/runner/main` keeps its files at the package root, not under `src/` —
that is this repository's layout, and the generated `BuildConfig.jl` goes
beside `InetRunner.jl`.

The workload levels mean this:

| level | the simulation half | the editor half (only when `:editor` is compiled in) |
| --- | --- | --- |
| `:none` | nothing | nothing |
| `:minimal` | the command line, one NED file, one INI file | every tier's atoms |
| `:demo` | the whole `tool/corpus` parse and one whole run | and their stub walks |
| `:full` | and a second, longer run | and one catalog page, opened and forced |

The editor half is one call: `InetExample.precompile_workload(level)`. That
function exists and takes these four symbols. Do not write a second one.

The corpus parse is the expensive half here and it is what `:demo` buys: a
Lerche transformer callback compiles the first time a grammar production
reaches it, and `tool/corpus/SOURCE.md` holds the measurement that says the
corpus is the way to reach them all.

## 5. The parameters

```julia
include("tool/Build.jl")                   # julia --project=tool
using .InetBuild

build_binary(editor_binary(; workload = :full))
build_binary(runner_binary())              # what the build makes today
```

The keyword set is the sibling plan's §4, with `inet-julia` and
`inet-julia-editor` as the derived names and `InetExample`'s demo directory as
the default catalog. A backend is a symbol here rather than a type, for the
reason the sibling's §3.5.1 gives: a build environment must not hold the stack
it builds.

`tool/Project.toml` held `Projectured` for the FSM generators and
`PackageCompiler` for the executable. It gained `Preferences`, which is how the
builder writes the parameters.

## 6. Phases

The phases are the sibling plan's, in the same order, so the two repositories
can be compared step by step.

### Phase 0 — wait for the seams — **partly answered, and not the way this plan asked**

- [ ] `ned_network_model` sits in `OmnetppDescription` (§3.1).
- [ ] The window sits in `OmnetppPresentation` (§3.2).

Both are changes in `omnetpp-julia`. Note the memory of this workspace: the
`[sources]` of this repository reach that repository's **main checkout**, so a
change made in a worktree there is not usable here until it lands on `main`.

**What landed on `omnetpp-julia` main instead.** That repository's own phase 3
built its editor package without either promotion, and moved three smaller
seams that are on `main` now and usable from here:

| seam | where it is |
| --- | --- |
| `ned_run_configuration(; ini_path, config, run_number)` | `OmnetppRunner`, public — the run of one configuration, read out of the INI file with no NED file opened |
| `run_limit(options, configuration, io)` | `OmnetppRunner`, public — what `--sim-time-limit` and the configuration together mean |
| `session_example_document(; limit, title, …)` | `OmnetppPresentationExample` — the window takes a `SimulationLimit` and a title now, not only an event count |

So phase 3 here can start, and it has a choice to make that this plan did not
have when it was written:

1. Take the same road the sibling took — depend on `OmnetppPresentationExample`
   for the window, and write this repository's own model seam beside
   `InetRunner.run_options`, which does not have one (§3.1).
2. Do the two promotions first, and let both editor packages be honest.

The sibling took road 1 and recorded the debt in its §6. Two callers now exist,
which is the condition its plan named for the promotion, so road 2 has become
the cheaper one to justify. Decide before writing `InetRunnerEditor`, not
after.

### Phase 1 — the builder takes parameters

- [x] `tool/Build.jl`, module `InetBuild`: `BuildSpec`, `validate`,
      `build_binary`, `build_preferences`, `spec_text`, `runner_binary()` and
      `editor_binary()`. It is the sibling's file with this repository's names,
      and with this repository's own measured run.
- [x] `tool/build_binary.jl` is the front end.
- [x] `cpu_target` is a parameter, and `INET_CPU_TARGET` is its
      environment-variable spelling.
- [x] `-u` is a real option: `Options.user_interface`, `interface_symbol`,
      `check_interface`, and `INTERFACES` on the entry package. `-u Editor` is
      refused and names the build that draws.
- [x] `--build-info`, and a help text whose `-u` line lists what the build
      holds.
- [x] `bin/inet-julia` resolves the environment once, the way the sibling's
      wrapper does. A fresh checkout has no Manifest.

**What the report measures here.** The sibling runs `Tictoc4` from its own
tutorial. This repository has no tutorial of its own: the one configuration it
runs end to end is `ActiveSourcePassiveSink` in the `inet-cpp` checkout beside
it. The report runs it when that checkout is there and says so when it is not,
because a missing measurement must not fail a build.

**Check.** `--no-compile` writes the parameters and prints the spec. The runner
suite is green — 159 tests, no failure — with the `-u`, the `--build-info` and
the build-spec assertions in it. A whole build was not run here.

### Phase 2 — the workload becomes a parameter — **done, except the numbers**

- [x] `package/runner/main/BuildConfig.jl` reads the level as a preference
      (§3.5 of the sibling plan — that is what replaced the generated file the
      plan first asked for, so there is no `*.default.jl` and nothing to add to
      `.gitignore`; `LocalPreferences.toml` is ignored already).
- [x] `tool/binary_precompile.jl` is cut into the four levels of §4. It reads
      `InetRunner.APP_WORKLOAD`, and the levels nest.
- [x] `--build-info` prints the level back.
- [ ] **Not measured.** The sibling measured the same knob on the same machine:
      `:full` builds a 702 MB bundle whose first run takes 0.50 s, and `:none`
      builds 689 MB and takes 7.39 s. This repository's trace has the same
      shape over a larger corpus, so the numbers would differ and the
      conclusion would not. Measure it when a build of this repository is made
      for a person to install.

### Phase 3 — the editor entry package

- [ ] `package/runner/editor/Project.toml` — `InetRunnerEditor`, with
      `InetRunner`, `InetExample`, `OmnetppPresentation`, `Projectured` and
      `ProjecturedSdl`. State in the file what the list means, the way
      `package/runner/main/Project.toml` states the opposite contract.
- [ ] `InetRunnerEditor.jl` — `main`, `julia_main`, the `-u` branch.
- [ ] `-u` in `CommandLine.jl`, and the refusal on the lean build.
- [ ] `bin/inet-julia-editor`, the developer wrapper. Copy the
      instantiate-once guard from `omnetpp-julia`'s `bin/omnetpp-julia`; this
      repository's wrapper has none, and a fresh checkout has no Manifest.

**Check.** The four commands of the sibling plan's phase 3, against
`TestNetwork`. The `-u Cmdenv` run through the editor wrapper must write
scalars identical to the lean binary's, line for line.

### Phase 4 — build the editor binary

- [ ] `BackendConfig.default.jl` and the generated file.
- [ ] `build_binary` accepts `:editor`.
- [ ] Measure and record the bundle, the start time and the first click.

**Check.** Lean, then editor, then lean again. The third bundle must equal the
first.

### Phase 5 — the assets travel with the binary

The fonts, the Adaptagrams shim and the demo catalog are read through paths
relative to a package source directory, and `create_app` does not bundle them.
The sibling plan's phase 5 holds the table and the fix. Here:

- [ ] The builder copies each into `build/<name>/share/`.
- [ ] Run the relocation test this repository already defines
      (`plan/done/native-simulation-binary.md` phase 4, steps 5 and 6):
      `env -i`, `HOME=/nonexistent`, no Julia on the path, and a copied
      directory. Add one step to it — move the checkout aside — because that is
      what catches a baked source path.

**The lean binary passes this test today.** Do not report the editor binary as
portable until it passes it too.

### Phase 6 — the tests and the guards

- [ ] `test_runner_closure()` is unchanged and still green.
- [ ] A new `test_editor_closure()`: the editor package **must** reach
      `OmnetppPresentation` and `ProjecturedVisual`, and `InetRunner` must
      still not reach either.
- [ ] A spec test: `build_binary(spec; compile = false)` renders both generated
      files, and the test asserts their text.
- [ ] A spec validation test: an empty `interfaces`, a `default_backend`
      outside `backends`, and `:editor` with no backend must each throw.

### Phase 7 — the documentation

- [ ] `documentation/architecture.md` — the row and the arrow.
- [ ] `package/runner/doc/runner.md` — the two binaries, `-u`, the parameters,
      the workload table.
- [ ] `README.md` — how to build each binary.
- [ ] Move this plan to `plan/done/`.

## 7. What this plan does not do

- **It does not add a run number.** `run_options` refuses every run but 0,
  because a configuration here fans out into one run. The window inherits that
  refusal.
- **It does not make the element libraries a parameter.** The binary holds
  `InetPacket` and `InetQueuing`, and that is fixed at the checkout.
- **It does not add a second backend.** `backends` is a real parameter with one
  legal value.
- **It does not save what the editor edits.**
