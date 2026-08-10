# The command-line runner

`inet-julia` runs one configuration of one simulation from a NED file and an
INI file, and writes the two result files OMNeT++ writes. It draws nothing and
opens no window.

```
inet-julia -f omnetpp.ini -c TestNetwork -r 0
```

## The options

| option | meaning | default |
|---|---|---|
| `-f <file>` | the INI file; a second one is refused, not dropped | `omnetpp.ini` |
| `-c <name>` | the configuration name | `General` |
| `-r <n>` | the run number, counted from 0 | `0` |
| `-n <path>` | NED directories, separated by `:`, searched recursively | the directory of the INI file |
| `-u <name>` | the user interface: `Cmdenv`, or `Editor` in the build that draws | `Cmdenv`, and `Editor` in the build that draws |
| `--result-dir=<dir>` | where the result files go | `results` |
| `--sim-time-limit=<t>` | stop at this simulation time; wins over the configuration's own | the configuration's |
| `--cpu-time-limit=<t>` | stop after this much wall-clock time | none |
| `--result-recording=<b>` | `false` turns off every recorder, and writes no file | `true` |
| `--cmdenv-express-mode=<b>` | accepted; this runner is always express | `true` |
| `--record-eventlog=<b>` | accepted only as `false`; no event log is written | `false` |
| `--engine=<name>` | `sequential` or `parallel` | `sequential` |
| `--workers=<n>` | worker threads for the parallel engine | one per thread but the colorizer's |
| `-h`, `--help` | print the options and exit | — |
| `-v`, `--version` | print the version and exit | — |
| `--build-info` | print what this build was made with and exit | — |

## The engine, and the threads it needs

```
JULIA_NUM_THREADS=8 inet-julia -c ActiveSourcePassiveSink --engine=parallel --workers=4
```

The option set and the refusals are `omnetpp-julia`'s, and
[its runner document](../../../../omnetpp-julia/package/runner/doc/runner.md)
explains what the engine does and why a thread count cannot be an option. The
short of it: this program hands its whole command line to `julia_main`, so
Julia's own option reader never sees a `--threads`, and the count comes from
the environment. `--build-info` prints how many threads the process got.

Measured here on `ActiveSourcePassiveSink`: the two engines write result files
that are identical line for line.

**The run walks the pipeline, not `run_network!`.** The shorthand takes a
simulation time, and this runner has to carry a wall-clock limit as well, which
only a whole `SimulationLimit` expresses. The six steps are the same either way.

**An option outside this set is an error.** It is not accepted and ignored. A
dropped `--sim-time-limit` would produce a run that is wrong in a way no output
shows, so the runner refuses rather than guess.

`opp_run` numbers runs from 0 and everything inside this repository numbers
from 1. `parse_command_line` is the one place the two meet.

## The exit codes

| code | meaning |
|---|---|
| 0 | the run finished |
| 1 | the command line is wrong |
| 2 | the run failed |

A runner is driven by scripts, so an exit code and one line on stderr are its
whole error report. No stack trace reaches the user; a log of a thousand runs
would drown in them.

## The result files

`<result-dir>/<Config>-#<run>.sca` and `.vec`, both carrying the same run
header:

```
version 3
run ActiveSourcePassiveSink-0-20260808-15:11:37-456059
attr configname ActiveSourcePassiveSink
attr datetime   20260808-15:11:37
attr inifile    …/omnetpp.ini
attr network    ProducerConsumerTutorialStep
attr processid  456059
attr runnumber  0

scalar ProducerConsumerTutorialStep.producer packets:count 11
```

The moment and the process id are in the run name because a path alone does not
tell two runs of one configuration apart.

A C++ file carries eleven more attributes, and every one of them describes a
parameter study: the iteration variables, the measurement, the experiment, the
repetition, the replication and the seed set. This runner runs one run of one
configuration, so each would be a constant. They arrive with the parameter
study.

## What it does not do

No parameter study — `${…}`, `repeat`, and `-r` over more than one run. No user
interface other than `Cmdenv`. No generic `--<key>=<value>` override, no event
log. A NED construct the builder does not cover — a submodule vector, a `like`
type, a conditional submodule — fails by name rather than silently.

## The rule this package lives under

**The editor must not be reachable from `package/runner/main`.** No
`ProjecturedVisual`, no `ProjecturedDomain`, no `Projectured` umbrella, no
`OmnetppLegacy`, no `DataFrames`, no `Revise`. `tool/build_binary.jl` compiles
this closure into an executable a user installs, and a runner draws nothing.

`InetRunnerTest.test_runner_closure()` walks `[deps]` through `[sources]` and
asserts it. Run it before and after any change to a `Project.toml` anywhere in
the closure — it is cheap, it needs nothing instantiated, and it is the only
thing that holds the rule.

`package/runner/test/` is free to depend on whatever it needs. A test is not
shipped.

## Building an executable

```
julia --project=tool tool/build_binary.jl            # inet-julia
```

The output is `build/<name>/`: an executable, a system image, and the shared
libraries they need. The name follows the interfaces the build holds, so two
builds never write into each other's directory. Copy the directory to a machine
with no Julia and run `bin/<name>`.

`tool/build_binary.jl` is a front end. `tool/Build.jl` is the builder, and
every flag is one of its keywords:

```julia
include("tool/Build.jl")        # julia --project=tool
using .InetBuild
build_binary(runner_binary(; workload = :demo, cpu_target = "native"))
```

`--help` lists the flags. `--no-compile` writes the parameters, prints the
spec, and stops, which is how a spec is checked without a build of several
minutes.

| flag | default | meaning |
|---|---|---|
| `--name=<name>` | from the interfaces | the executable name and the directory |
| `--workload=<level>` | `full` | how much the build compiles ahead of time |
| `--cpu-target=<target>` | portable | which processor the image is for |
| `--output=<dir>` | `build/<name>` | where the bundle goes |

The parameters travel to the program as preferences, in the entry project's
`LocalPreferences.toml`, and the entry package reads them at module scope. So
the value is compiled into the image, the bundle needs no file beside it, and a
build under other parameters rebuilds rather than reuses. `--build-info` prints
them back.

`bin/inet-julia` in the checkout runs the same entry point through
`julia --project=package/runner/main`, for a change you want to try without a
build. A `Manifest.toml` is gitignored, so the first run in a fresh checkout
resolves that environment and says it is doing so.

### How much the build compiles ahead of time

A run costs about **0.5 s**, of which 0.3 s is starting the image at all. The
simulation itself is around 10 ms of it; the rest is reading the two files and
building the network.

That number depends on `tool/binary_precompile.jl`. A Lerche transformer
callback compiles the first time a grammar production reaches it, so a build
that parses little makes a program that compiles inside the user's run — 5.1 s
of it, before the corpus existed.

| `--workload` | what the build runs |
|---|---|
| `none` | nothing |
| `minimal` | the paths that answer without running, one NED file, one INI file |
| `demo` | and every NED and INI file in `tool/corpus/`, and one whole run |
| `full` | and two real configurations out of the corpus |

`full` is the default and it is what the build did before it took a parameter.
Take a lower level for a day spent changing the runner. If you shrink what the
build parses, time a run before and after.

The parse tables are the other half. They are built at precompile time in
`OmnetppFormat`, as a `const` rather than a lazy singleton, so they are
deserialized rather than reconstructed — 122 ms a run that would otherwise be
spent building the same tables again. Phases 7 and 8 of
[native-simulation-binary.md](../../../plan/done/native-simulation-binary.md)
carry both measurements.
