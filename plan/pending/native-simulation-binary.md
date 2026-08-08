# A native binary that runs a simulation from a NED file and an INI file

**Status:** phases 2, 3 and 4 done (2026-08-08), in the worktree
`/home/projectured/workspace/inet-julia-binary` on branch `binary`. Phase 0 was
done by the companion plan. Phase 1 is split: the stale dependency is fixed,
the package move waits. Phases 5 and 6 wait on `first-run-from-ned-ini.md`.
§6 carries the state of each phase.

**The binary exists.** `tool/build_binary.jl` produces a 735 MB directory that
runs a simulation in 0.38 s on a machine with no Julia, against 4.53 s for the
same run through the checkout. Its scalars are identical to the ones the
checkout writes.

**Goal:** ship one executable that runs an INET simulation from an unmodified
NED file and an unmodified INI file, with no user interface, no Julia
installation, and no part of the editor inside it.

The one command this plan must make work:

```
inet-julia -f omnetpp.ini -c TestNetwork -r 0
```

**Depends on:** `omnetpp-julia/plan/pending/first-run-from-ned-ini.md`. That
plan builds the NED reader, the INI reader and the type registry in a new
package `OmnetppDescription`. §5 states the exact seam this plan calls, so most
of the work proceeds before that plan lands. **§2.4 amends it**: the dependency
edge between `OmnetppDescription` and `OmnetppLegacy` must run the other way.

**Mitigates:** `RISK-BINARY-DISTRIBUTION` in
`omnetpp-julia/documentation/risks.md`.

---

## 1. Goal

A user gets one directory, copies it to a machine, puts it on the path, changes
to a simulation folder and runs the command above. No Julia, no
`Pkg.instantiate`, no sibling checkouts, no `setenv`.

The command must behave like `opp_run` for the options in §4.4: the same option
letters, the same result-file names, the same exit codes. A script that drives
`opp_run` today must drive this binary after a change of the program name
alone.

The bar is a minimum viable product. One configuration, one run number, one
user interface, no parameter study.

## 2. What the binary must not contain

The runner writes result files. It draws nothing, it opens no window and it
reads no user gesture. **The editor must not be in its dependency closure.**
This is a requirement of the package, not a size to measure afterwards.

### 2.1 The rule

`package/runner/main/Project.toml` must not reach, at any depth:

| excluded | lines | what it is |
| --- | --- | --- |
| `ProjecturedVisual` | 29 042 | syntax, text, widget, layout, font, colour |
| `ProjecturedDomain` | 36 226 | the domains, Markdown, Base64 |
| `Projectured` | — | the umbrella, which names both |
| `OmnetppLegacy` | — | the projections and the C++ launcher |
| `DataFrames` | — | the result reader, which the binary does not use |
| `Revise` | — | a development tool |

That is 65 268 lines of editor code the binary never loads.

The rule binds `main/` only. `package/runner/test/` may depend on whatever it
needs, because a test is not shipped.

### 2.2 The floor, and why it is not lower

| kept | lines | why |
| --- | --- | --- |
| `ProjecturedKernel` | 14 380 | `@document` and the cells — `OmnetppSimulator` declares its model, engine and execution types with them |
| `ProjecturedBase` | 5 886 | `PrimitiveModule`, `CollectionModule`, `DomainModule` — the parameter and collection types the simulator and the NED documents use |

`ProjecturedKernel` has no external dependency at all, and `ProjecturedBase`
adds two standard libraries. Together they are the reactive document substrate
that the simulator is written in, not the editor. To remove them is to rewrite
`OmnetppSimulator`, and this plan does not propose that.

The rest of the closure is `InetQueuing`, `InetCommon`, `InetPacket`,
`OmnetppSimulator`, `OmnetppUnits`, `OmnetppDescription`, and the external
packages `Lerche`, `Unitful`, `DataStructures` and `SHA`.

### 2.3 The measurement that says the split works

`OmnetppLegacy` is one package that holds two halves with different dependency
sets. This was measured, not assumed.

| half | lines | the Projectured submodules it names |
| --- | --- | --- |
| the NED and INI documents, their three parsers, `Quantity.jl` | 1 678 | `CellModule`, `DocumentModule`, `ReferenceModule` (kernel); `CollectionModule`, `DomainModule` (base) |
| the projections, the C++ launcher, the result reader, the file documents | 3 413 | the above plus `SyntaxModule`, `TextModule`, `WidgetModule`, `LayoutModule`, `FontModule`, `ColorModule`, `StyleTextModule`, `NaturalProjectionModule` |

**The lean half names nothing from `ProjecturedVisual` and nothing from
`ProjecturedDomain`.** The parser grammars are `raw"""` constants in the
source, so they carry no data file either. The split is therefore a move of
seven files and one rebind block, not a rewrite.

### 2.4 Where the lean half goes

**Move the lean half into `OmnetppDescription`,** the package that
`first-run-from-ned-ini.md` creates, and make `OmnetppLegacy` depend on it.

This amends that plan's phase 1, which states the opposite edge
(`OmnetppDescription` depends on `OmnetppLegacy`). With that edge the binary
pulls the whole editor, so it cannot stand.

The names then say what each package is. `OmnetppDescription` owns the
description of a simulation — the NED file, the INI file, and the network they
build. `OmnetppLegacy` owns the bridge to the C++ product — the launcher, the
result reader, and the projections that put a NED file on screen.

The repository already isolates a heavy dependency this way:
`package/legacy/plot` exists to keep CairoMakie out of `OmnetppLegacy`. This
is the same move, for the same reason.

### 2.5 One dependency is simply stale

`OmnetppSimulator` lists `Revise` in `[deps]`. No source file uses it. The
single occurrence of the word in the package is a comment in
`checkpoint/Checkpoint.jl`. Delete the entry.

## 3. What exists today

| piece | state |
| --- | --- |
| a NED parser | exists — reads 1671 of INET's 1672 `.ned` files |
| an INI parser | exists — reads `omnetpp.ini` into its sections |
| a NED tree turned into a `Network` | **missing** — the companion plan, phase 5 |
| a NED type name resolved to a Julia type | **missing** — the companion plan, phase 2 |
| an INI `[Config …]` turned into parameter rules | **missing** — the companion plan, phase 4 |
| the five lifecycle verbs of a run | exists — `expand_simulation`, `instantiate_simulation`, `prepare_simulation_execution`, `run_simulation!`, `finish_simulation!` |
| a run limit | exists — `simulation_limit(; sim_time, events, wall_clock)` |
| `.sca` and `.vec` output | exists — `OmnetppTextSink`, drained by `finish_simulation!` |
| OMNeT++ result-file names and run attributes | **missing** |
| a command line | **missing** |
| a binary of any kind | **missing**, in every repository of the stack |

## 4. Decisions

### 4.1 Use PackageCompiler, not juliac

`create_app` from PackageCompiler.jl produces a directory with an executable, a
system image and the shared libraries it needs. It permits dynamic dispatch.

`juliac` in Julia 1.12 forbids dynamic dispatch under `--trim`. This design
depends on dynamic dispatch: the element library dispatches on module type at
every gate, and `OmnetppSimulator` dispatches on engine type.
`omnetpp-julia/documentation/julia-vs-rust-language-assessment.md` already
records this.

**Take PackageCompiler.** Re-measure `juliac` per Julia release, and treat a
switch as a later plan.

### 4.2 One new component, `package/runner/`

The package is `InetRunner`. The executable is `inet-julia`.

A runner earns a package under `IAR-LOWEST-PACKAGE`: its dependency set is one
no existing package has, and it is the only package here bound by the rule of
§2.1. Its consumer is a command line, not a Julia caller. Nothing depends on
it, so the graph stays acyclic.

It does **not** go in the `Inet` umbrella. The umbrella depends on
`ProjecturedVisual` for the packet diagram, and §2.1 forbids that.

### 4.3 The command line knows no INET name

`InetRunner` splits in two. `CommandLine.jl` parses arguments and names nothing
from INET. `Runner.jl` calls the seam of §5 and the lifecycle verbs.

The reason is a second consumer. `omnetpp-julia` will want the same binary for
a model that is not INET. When it does, `CommandLine.jl` moves down into
`OmnetppDescription` unchanged, and `inet-julia` keeps only the type
registration and the application project.

### 4.4 The option set

Support these, and nothing else.

| option | meaning | default |
| --- | --- | --- |
| `-f <file>` | the INI file; repeatable | `omnetpp.ini` |
| `-c <name>` | the configuration name | `General` |
| `-r <n>` | the run number, 0-based | `0` |
| `-n <path>` | NED directories, separated by `:` | the directory of the INI file |
| `-u <name>` | the user interface; only `Cmdenv` is accepted | `Cmdenv` |
| `--result-dir=<dir>` | where the result files go | `results` |
| `-h`, `--help` | print the options and exit 0 | — |
| `-v`, `--version` | print the version and exit 0 | — |

**An unknown option is an error.** Print the option on stderr and exit 1. Do
not accept and ignore it. A silently ignored `--sim-time-limit` produces a run
that is wrong in a way no output shows.

Exit codes: 0 for a run that reached its limit or ran out of events, 1 for a
bad command line, 2 for a run that failed. Fix them in phase 2 and do not
change them after.

### 4.5 The run number is 0-based outside and 1-based inside

OMNeT++ numbers runs from 0. This repository numbers `run_id` from 1, and all
indexing here is 1-based. Convert once, in `CommandLine.jl`.

For the minimum viable product a configuration without a sweep fans out into
one run, so only `-r 0` is valid. A larger `-r` fails with the count of runs
the configuration has.

### 4.6 The result files follow the OMNeT++ names

`OmnetppTextSink` writes the file content already. The names and the run
attributes are what is missing.

- The scalar file is `<result-dir>/<Config>-#<run>.sca`.
- The vector file is `<result-dir>/<Config>-#<run>.vec`.
- The run name is `<Config>-<run>-<datetime>-<pid>`.
- The run attributes are `configname`, `runnumber`, `network`, `datetime`,
  `processid` and `inifile`.

`opp_scavetool` and the `OmnetppLegacy` result readers both key on these, and
phase 6 compares a Julia file against a C++ file with one tool.

### 4.7 Build the binary before the reader lands

Two things here are uncertain, and they are independent. The packaging is
uncertain because nothing in this stack was ever packaged. The NED path is
uncertain because the reader does not exist.

**Do the packaging first, against a network that already runs.** Phases 2 to 4
select a model by name from a small table, so the whole path from the command
line to a `.sca` file works before a NED file enters. Phase 5 then replaces one
function. Nothing before it is thrown away.

## 5. The seam this plan calls

Write phases 2 to 4 against these three functions. The companion plan delivers
them. Until it does, a stub in `package/runner/test/` answers them.

```julia
# What one [Config …] says: the network to build, the run limit, and the
# ordered parameter rules.
read_ini_configuration(ini_path, config_name) -> IniConfiguration

# The NED tree of `network_name`, built into a runnable Network.
build_network(ned_files, network_name, rules) -> Network

# A NED type name resolved to the Julia type registered for it.
ned_type(name) -> Type
```

`IniConfiguration` carries `network::String`, `limit::SimulationLimit` and
`rules`. `sim-time-limit` is a limit and not a parameter, and the companion
plan's phase 4 already separates the two.

## 6. Phases

Work in a worktree at `/home/projectured/workspace/inet-julia-binary`, and for
phase 1 at `/home/projectured/workspace/omnetpp-julia-description`. Each must
be a sibling of its checkout, or the relative `[sources]` break. Run
`Pkg.instantiate()` in a fresh worktree, because `Manifest.toml` is gitignored.
Commit at the end of each phase, and mark the phase done here.

### Phase 0 — Capture the oracle — **done elsewhere**

The companion plan captured it first. `inet-julia` commit `fe8253f` on branch
`ned-run` holds `ActiveSourcePassiveSink-#0` and `PacketQueue-#0`, both `.sca`
and `.vec`, under `package/queuing/test/inet-reference/queueing/`, with a
`PROVENANCE.md` that records the `inet-cpp` commit `b52bc21a`, OMNeT++ 6.4.0
release, the exact command and the `LD_LIBRARY_PATH` the prebuilt binaries
need.

**Point at those files. Do not make a second copy.** Phase 6 reads them from
there.

The header they carry is the target of phase 3:

```
version 3
run ActiveSourcePassiveSink-0-20260808-11:35:28-178086
attr configname ActiveSourcePassiveSink
attr datetime 20260808-11:35:28
…
scalar ProducerConsumerTutorialStep.producer packets:count 11
```

Warning: do not name a destination folder `results`. `.gitignore` holds
`results/`, which matches that name at any depth, and git would drop the
reference files without a word.

### Phase 1 — Split the readers out of the editor stack — **step 6 done, the rest waits**

This phase lands in `omnetpp-julia`.

**Step 6 is done.** `OmnetppSimulator` no longer declares `Revise`
(`omnetpp-julia` branch `binary`, "A development tool is not a dependency of
the engine"). The guard of phase 2 found it on its first run, and the build of
phase 4 proved it was not academic: `Revise` precompiled into the shipped image.

**Steps 1 to 5, 7 and 8 wait.** `package/description` already exists on
`omnetpp-julia` branch `ned-run`, created by the companion plan's own phase 1
with `OmnetppDescription` depending on `OmnetppLegacy` — the edge §2.4 says
must run the other way. To create the same package from `main` in a second
worktree would collide with that branch at every file.

**Do the move on top of `ned-run`, after it lands.** Nothing in phases 2 to 4
needs it: the runner does not depend on `OmnetppDescription` until phase 5.

1. Create `package/description/{main,test}`, each with a `Project.toml`.
   `OmnetppDescription` depends on `ProjecturedKernel`, `ProjecturedBase`,
   `Lerche` and `OmnetppUnits`, and on nothing else.
2. Move seven files into it: `document/Ini.jl`, `document/Ned.jl`,
   `document/Test.jl`, `parser/IniParser.jl`, `parser/NedParser.jl`,
   `parser/TestParser.jl` and `simulation/Quantity.jl`.
3. Give the new module root the rebind block for the five submodules of §2.3,
   the same way `OmnetppLegacy.jl` does today.
4. Add `OmnetppDescription` to `OmnetppLegacy`'s dependencies, and rebind the
   moved submodules there so `IniToSyntax.jl` and `NedToSyntax.jl` still
   resolve `..IniModule` and `..NedModule`.
5. Re-export the moved names from `OmnetppLegacy`, so no caller changes.
6. Delete the stale `Revise` entry of §2.5.
7. Add the package to the `Omnetpp` umbrella, to the root `[sources]`, to
   `test/runtests.jl` and to the inventory in `SEALING.md`.
8. Instantiate the new environment standalone, not only from the root.

Check: `julia --project=package/description/main -e 'using OmnetppDescription;
nedparse_file(…)'` parses a NED file in an environment that has no
`ProjecturedVisual` in it at all. Run the existing legacy suite unchanged, to
prove the re-export is complete.

### Phase 2 — The package, the command line, and the guard — **done**

Two facts came out of it.

The entry file sits at the package root and not under `src/`, because that is
what every package here does (`entryfile = "InetRunner.jl"`). The paths in the
steps below say `main/src/`, and the code is at `main/`.

**The guard earned itself on its first run.** It found `Revise` in the closure,
declared by exactly one project file in the whole graph. Phase 4 then showed
that this was not academic: `Revise` precompiled into the shipped image. The
assertion stays red until `omnetpp-julia` branch `binary` lands.

1. Create `package/runner/{main,test}`, each with a `Project.toml`.
   `InetRunner` depends on `InetQueuing` and `OmnetppSimulator`.
2. Add `InetRunner` and `InetRunnerTest` to the root `[deps]` and `[sources]`,
   and add `test_runner()` to `test/runtests.jl`.
3. Write the guard first, and let it fail: `test_runner_closure()` resolves the
   dependency closure of `package/runner/main` and asserts that none of the six
   names of §2.1 appears. Both repositories already carry static layering
   guards, and this is one more.
4. Write `main/src/CommandLine.jl`: `parse_command_line(args) -> Options`, the
   help text and the version text. It touches no global state and no file.
5. Write `main/src/Runner.jl`: `run_options(options) -> Cint`. It selects the
   model, builds the run, prepares the execution, runs it and finishes it.
6. Write `main/src/InetRunner.jl` with `julia_main()::Cint`. It reads `ARGS`,
   calls `run_options` and returns the exit code. Catch every error there,
   print one line on stderr and return 2.
7. Select the model from a table of built-in names for now, with `QueuingModel`
   as the first entry. Phase 5 deletes the table.
8. Write `bin/inet-julia`, a shell script that runs the same entry point
   through `julia --project=package/runner/main`.

Check: `bin/inet-julia -c Queuing -r 0` runs, writes a `.sca` file and exits 0.
An unknown option exits 1 and names the option. `-u Qtenv` exits 1. `-r 1`
exits 1 and reports the count of runs. The guard passes.

Result: every check holds. The suite is 58 pass, 1 fail — the `Revise`
assertion.

### Phase 3 — The result files — **done**

1. Give `run_options` the result directory, and create it when it is absent.
2. Name the `.sca` and the `.vec` file per §4.6.
3. Build the run name and the six run attributes, and pass them to
   `OmnetppTextSink`.
4. Read the file back in the test package and assert every attribute. Nothing
   new parses a result file.

Check: the header of a Julia `.sca` and the header of the phase 0 `.sca` differ
only in the values that must differ — the datetime, the process id and the
numbers.

Result: the header holds. The suite is 83 pass, 1 fail. Two facts came out of
it.

**The scalar module column is empty, and that is a defect the plan missed.**
§4.6 named the file names, the run name and the attributes, and said nothing
about the columns of a `scalar` line. A recorder keeps scalars in one flat
namespace, so `InetQueuing.record_statistic!` writes the module into the name:
`Queuing.queue.packets:count`. OMNeT++ writes
`scalar Queuing.queue packets:count`. `OmnetppTextSink` put the whole name in
the second column and left the first empty.

The fix is a `split_module_path` keyword on the sink, committed on
`omnetpp-julia` branch `binary` ("A dotted scalar name fills both columns of a
scalar line"). It splits at the last dot, because a module path holds dots and
a statistic name holds a colon. It is off by default, so no existing file
changes. `Runner.jl` says where the one line goes when that branch lands.

**Six attributes, not seventeen.** A C++ file carries eleven more, and every
one of them describes a parameter study: `experiment`, `measurement`,
`replication`, `repetition`, `seedset`, `iterationvars` and its three
spellings, `datetimef`, `resultdir`. This runner runs one run of one
configuration, so each would be a constant. They arrive with the parameter
study, which §10 puts out of scope.

### Phase 4 — The binary — **done**

This is the phase that had never been done in this stack.

1. Add `PackageCompiler` to `tool/Project.toml`.
2. Write `tool/build_binary.jl`. It runs `Pkg.instantiate()` on
   `package/runner/main`, then `create_app` with
   `executables = ["inet-julia" => "julia_main"]` and
   `include_lazy_artifacts = true`. The output goes to `build/inet-julia/`.
   Add `build/` to `.gitignore` in the same commit.
3. Write `tool/binary_precompile.jl`, the precompile execution file. It runs
   one short simulation to a `.sca` file in a temporary directory, and takes
   the help path, the version path and the two error paths. Without it the
   first run of the binary compiles everything again. It parses no NED and no
   INI string yet — the runner does not read one until phase 5, which adds it.
4. Measure three numbers and record them here: the size of the bundle, the wall
   time of `inet-julia --version`, and the wall time of one run against the
   same run under `julia --project`.
5. Run the bundle with `env -i`, with only the bundle's `bin` on the path, and
   with no Julia installed. That is the test of relocatability, and nothing
   else is.
6. Copy the bundle to a second directory and run it there. A path baked at
   build time shows up here and nowhere else.

Check: every check of phase 2 and phase 3 passes again, through the built
binary instead of through `julia --project`.

Result, measured on this machine, Julia 1.12.6, Linux:

| number | value |
| --- | --- |
| the bundle | 735 MB |
| `inet-julia --version` | 0.34 s |
| one run, built binary | 0.38 s |
| the same run, `julia --project` | 4.53 s |

The bundle runs under `env -i` with `HOME=/nonexistent` and no system Julia on
the path, and it runs the same from a copied directory. Its scalars are
identical, line for line, to the ones the checkout writes.

**The event rate was not measured, and the plan asked for it.** A rate needs a
run long enough to swamp the start, and `QueuingModel` fixes its own time limit
at 100 s — 983 events. The command line cannot override a parameter, by §10.
The wall time of the whole run is the number in the table instead, and it is
the one a user feels. Measure the rate in phase 6, where a configuration sets
its own limit.

**Ship what `-t` a user needs.** The bundle takes its thread count from
`JULIA_NUM_THREADS`, and nothing sets it. The sequential engine does not care.
The parallel engine would.

### Phase 5 — The NED file and the INI file — **blocked**

This phase needs the companion plan. Do not start it before that plan's phase 5
is done. Its phases 1 to 3 are done on `omnetpp-julia` branch `ned-run`:
`OmnetppDescription` exists with the identifier mapping, the type registry and
the expression evaluator. Phases 4 and 5 — the INI configuration reader and
`build_network` — are not.

Phase 1 of this plan must land before this one, or adding
`OmnetppDescription` to `InetRunner` puts the whole editor in the executable.

0. Add `split_module_path = true` to the sink in `Runner.jl`, and the module
   column of every scalar line becomes the one OMNeT++ writes. One line; the
   sink option is already committed.

1. Add `OmnetppDescription` to `InetRunner`'s dependencies. Run the guard of
   phase 2 step 3 again — after phase 1 it must still pass.
2. Resolve `-n` into a list of `.ned` files. Scan each directory of the path
   recursively. When `-n` is absent, use the directory of the INI file.
3. Replace the built-in model table of phase 2 step 7 with the seam of §5.
4. Take the run limit from `sim-time-limit`, and pass it to
   `prepare_simulation_execution`.
5. Report every INI key that matched no parameter. Do not fail the run for it.
6. A NED type that resolves to nothing fails with its NED type name and with
   the file it appeared in. It must never fall back to a default.

Check: `inet-julia -f omnetpp.ini -c ActiveSourcePassiveSink -r 0`, run inside
`inet-cpp/tutorials/queueing`, builds the right network. Assert every submodule
name, every submodule type, every connection and every resolved parameter.

### Phase 6 — Compare against the C++ result — **blocked**

1. Run `ActiveSourcePassiveSink` and `PacketQueue` with the built binary,
   against the unmodified files of `inet-cpp/tutorials/queueing`.
2. Compare each `.sca` against the phase 0 reference. Level 1 is the structure.
   Level 2 is the recorded statistics, within the bound the run supports. The
   two levels are defined in `plan/pending/queueing-tutorial-from-ned-ini.md`
   §4.3.
3. Add the comparison to `package/runner/test/`. Skip it, and say so, when the
   `inet-cpp` checkout is absent.

**Done when both configurations run through the built binary, on a machine with
no Julia, and their statistics agree with the C++ reference.**

## 7. Where the code goes

In `omnetpp-julia`:

- `package/description/main/src/` — the seven moved files and the new module
  root.
- `package/description/test/` — its suite.

In `inet-julia` (the entry file sits at the package root, not under `src/`,
which is what every package here does):

- `package/runner/main/InetRunner.jl` — the module and `julia_main`.
- `package/runner/main/CommandLine.jl` — the parse, the help, the version.
- `package/runner/main/Runner.jl` — the seam and the lifecycle.
- `package/runner/main/ResultFiles.jl` — the names, the run name, the
  attributes.
- `package/runner/test/` — `closure.jl`, `command_line.jl`, `run.jl`,
  `result_files.jl`, and later the stub of §5 and the comparison of phase 6.
  Phase 0's reference files stay where the companion plan put them, under
  `package/queuing/test/inet-reference/queueing/`.
- `package/runner/doc/runner.md` — the option table, the exit codes, and the
  rule of §2.1 with the reason for it. Written when phase 5 fixes the options.
- `bin/inet-julia` — the developer wrapper.
- `tool/build_binary.jl`, `tool/binary_precompile.jl` — the build.
- `build/` — gitignored output.

## 8. Tests

```
julia --project=package/description/test -e 'using OmnetppDescriptionTest; test_description()'
julia --project=package/runner/test      -e 'using InetRunnerTest; test_runner()'
julia --project=. test/runtests.jl
```

Only the `Fail` and `Error` counts matter.

The build is not a test. Run `tool/build_binary.jl` by hand, and record the
three numbers of phase 4 step 4 here each time they change by more than a
tenth.

## 9. Risks

- **The closure guard is the only thing that holds the rule.** A dependency
  added for one convenience puts the editor back. Write the guard in phase 2,
  before the package has anything in it, so it never has to be recovered.
  Measured: it found a real one on its first run.
- **A change to the runner's closure lands in another repository.** Both of the
  two found so far do — the stale `Revise` and the scalar module column. Each
  is committed on `omnetpp-julia` branch `binary`, and neither is visible from
  here until that branch lands, because `[sources]` reach the main checkout by
  relative path. Do not repoint a `[sources]` entry at a worktree to see it
  sooner. A dangling `omnetpp-julia-<name>` path survives the merge and the
  root environment hides it.
- **A file read at run time breaks in the bundle.** The NED grammar and the INI
  grammar are `raw"""` constants in the source, so they travel inside the
  image. Search the closure for every other run-time read of a file beside a
  source file, and list what is found. Phase 4 step 6 catches one.
- **The first parse is slow.** Both parsers build their LALR tables lazily, on
  first use, into a `Ref`. The tables are therefore not in the image, only the
  code that builds them. Measure the first parse. If it costs more than a
  second, decide whether the tables can be built at precompile time, and record
  the answer here.
- **A registry filled from `__init__` is empty.** The NED type registry fills
  when `InetQueuing` loads. In an application image `__init__` runs at start,
  so this works — but assert the registry is not empty before the first lookup,
  so a failure names the cause instead of a missing type.
- **The reader must not call `eval` at run time.** An application image has a
  fixed world age. A reader that generates code for a NED type would work under
  `julia --project` and fail in the binary. State this to the companion plan
  before its phase 5 starts.
- **Phase 1 touches another repository.** Nothing in `package/legacy/` is
  sealed today, so no permission is needed for the move — but `SEALING.md`
  carries the file inventory and must change in the same commit.
- **Threads.** The parallel engine needs threads, and an application image
  takes the thread count from `JULIA_NUM_THREADS`. The minimum viable product
  is sequential, so this only has to be documented.

## 10. Out of scope

- A parameter study. `${…}`, `repeat`, `-r` over more than one run, and
  `opp_runall` belong to `omnetpp-julia/plan/pending/deep-parameter-studies.md`.
- Every option not in the table of §4.4, including the generic
  `--<key>=<value>` override, `--debug-on-errors`, the event log and the
  `Cmdenv` express-mode settings.
- Any user interface. No Qtenv, no window, no progress bar beyond one line.
- A bundle for Windows or macOS. Build for Linux, and record what a second
  platform would cost.
- A smaller floor than §2.2. `ProjecturedKernel` and `ProjecturedBase` stay,
  because `OmnetppSimulator` is written in them.
- Protection of model source. A Julia bundle ships source in its image, and
  `RISK-BINARY-DISTRIBUTION` says so. A closed model needs a licence or a
  hosted service, not this binary.
- The C++ compatibility route of
  `omnetpp-julia/plan/pending/omnetpp-compatibility.md`. That plan runs
  unmodified C++ INET on the Julia engine. This one runs the Julia element
  library from the C++ input files. They meet nowhere.
