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
| `-f <file>` | the INI file; repeatable, and the first one is read | `omnetpp.ini` |
| `-c <name>` | the configuration name | `General` |
| `-r <n>` | the run number, counted from 0 | `0` |
| `-n <path>` | NED directories, separated by `:`, searched recursively | the directory of the INI file |
| `-u <name>` | the user interface; only `Cmdenv` is accepted | `Cmdenv` |
| `--result-dir=<dir>` | where the result files go | `results` |
| `-h`, `--help` | print the options and exit | — |
| `-v`, `--version` | print the version and exit | — |

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

## Building the executable

```
julia --project=tool tool/build_binary.jl
```

The output is `build/inet-julia/`: an executable, a system image, and the
shared libraries they need. Copy the directory to a machine with no Julia and
run `bin/inet-julia`.

`bin/inet-julia` in the checkout runs the same entry point through
`julia --project=package/runner/main`, for a change you want to try without a
build.

**A run costs about five seconds of fixed overhead**, almost all of it the NED
and INI parsers building their LALR tables. They build lazily into a `Ref`, so
the tables never reach the system image. See the end of §6 of
[native-simulation-binary.md](../../../plan/done/native-simulation-binary.md).
