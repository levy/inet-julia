# The options this repository's executables accept

`inet-julia` accepts six options and refuses five that `omnetpp-julia` accepts.
Neither it nor the editor executable it does not have yet can ask for the
parallel engine.

This plan closes both gaps. **It is the second of a pair.** `omnetpp-julia`'s
`plan/pending/executable-options.md` defines the option names, the refusals and
the reasons; this one applies them here and adds the catching up that only this
repository needs. Land that one first, and copy its spellings rather than
inventing a second set.

## 1. Goal

1. **The five missing options arrive**, in `omnetpp-julia`'s spellings and with
   its refusals.
2. **The engine becomes an option**, `--engine=parallel` with `--workers`.
3. **The editor executable gets them too**, when
   `plan/pending/executable-with-user-interface.md` phase 3 builds it.

## 2. What is missing, and what it costs

| option | `omnetpp-julia` | `inet-julia` | what its absence costs |
| --- | --- | --- | --- |
| `--sim-time-limit=` | yes | **no** | a run stops only where the INI file says, so one configuration cannot be cut short for a smoke test |
| `--cpu-time-limit=` | yes | **no** | nothing bounds a run by wall time |
| `--result-recording=` | yes | **no** | the cheapest run a speed measurement wants cannot be asked for |
| `--cmdenv-express-mode=` | yes | **no** | a script written for `opp_run` fails on an option this runner ignores anyway |
| `--record-eventlog=` | yes | **no** | the same, for the option that must be refused as `true` |
| `--engine=`, `--workers=` | no | no | the sibling plan's §1 |

The suite already shows the first one. `package/runner/test/run.jl` asserts the
refusal, and the output reads:

```
inet-julia: unknown option '--sim-time-limit=100s' — run inet-julia -h for the ones that exist
```

## 3. Two differences to settle while the sets are being aligned

### 3.1 `-f` is repeatable here and refused there

`inet-julia` pushes every `-f` onto a list and reads the first.
`omnetpp-julia` refuses a second one, and says why: a rule from a file that was
accepted and never read is the failure the option set exists to prevent.

**Take `omnetpp-julia`'s refusal.** One reader, one behaviour. A caller that
passes two INI files today gets a run from the first and no warning, which is
the case that refusal was written for.

### 3.2 The run number

`omnetpp-julia` expands a configuration into runs and `-r` indexes them.
`inet-julia` refuses every run but 0, because a configuration here fans out into
one run until a parameter study does otherwise.

**Leave it.** It is a limit of the reader, not of the option, and the message
already says so. It leaves this plan's scope with nothing to do.

## 4. The seam this plan needs

`InetRunner.run_options` runs through `run_network!`, and `run_network!` takes
no engine — it builds the sequential one, always. `omnetpp-julia`'s runner walks
the pipeline instead and hands `prepare_simulation_execution` an `EngineSpec`.

Two ways, and the first is the one to take:

1. **Give `run_network!` an `engine` keyword**, defaulting to the sequential
   spec. It is one keyword and one line inside a function that is already the
   shorthand over `prepare → run → finish`; every one of its 54 callers in this
   repository keeps working unchanged. A change in `omnetpp-julia`.
2. Rewrite `run_options` onto the pipeline, the way the sibling's runner is
   written. It is the more honest shape and it is a bigger change, and the
   reason the sibling gives for it — the statistic overrides must reach the
   recorder before any module registers — does not apply here.

Take 1 now and leave 2 to whoever needs the overrides.

## 5. Phases

### Phase 0 — wait for the sibling — **done**

- [x] `omnetpp-julia`'s plan, phase 1. It defines `--engine`, `--workers`, the
      thread refusal and the `--build-info` rows.
- [x] `run_network!` takes an `engine` keyword (§4) — landed, and then not
      needed here. Phase 2 says why.

Both are changes in `omnetpp-julia`, and the `[sources]` of this repository
reach that repository's **main checkout**, so neither is usable here until it
lands on `main`.

### Phase 1 — the five options — **done**

- [x] `Options` gains `sim_time_limit`, `cpu_time_limit`, `express_mode` and
      `result_recording`, with the sibling's types and defaults.
- [x] `parse_command_line` reads all five, refuses `--record-eventlog=true`,
      and refuses a second `-f` (§3.1). The value helpers are the sibling's,
      including `parse_omnetpp_quantity`, so `100s`, `1000ms` and a bare number
      mean here what they mean in an INI file.
- [x] `run_options` honours them: the limit wins over the configuration's, no
      recorder is built when recording is off, and the run then says
      `Results: none — recording is off.` rather than naming files it did not
      write.
- [x] The help text lists them.

**Check — done.** `--sim-time-limit=3s` cuts `ActiveSourcePassiveSink` from
t=10.0 to t=3.0. `--result-recording=false` creates no result directory at all.
`--record-eventlog=true` and a second `-f` are refused by name.

**Two assertions had to change, and both were the plan's own point.**
`command_line.jl` and `run.jl` each asserted that `--sim-time-limit=100s` is
refused — the exact drift this plan removes. They now assert the refusal of an
option that still does not exist, which keeps the intent the comment states:
an option this build does not honour must not be quietly dropped.

### Phase 2 — the engine — **done**

- [x] `--engine=` and `--workers=`, with the sibling's names and refusals.
- [x] `check_engine` — the thread refusal, naming `JULIA_NUM_THREADS`.
- [x] `--build-info` prints the thread count.
- [x] `run_options` passes the spec to the **pipeline** — see below.

**§4 chose the wrong road, and `--cpu-time-limit` is why.** That section said to
give `run_network!` an `engine` keyword and leave the pipeline to whoever needs
the statistic overrides. The keyword landed on `omnetpp-julia` main and is worth
having for its other callers, but this runner did not end up using it: the
shorthand takes a **simulation time**, and phase 1 has to carry a wall-clock
limit as well, which only a whole `SimulationLimit` expresses. So `run_options`
walks `initialize → check → prepare → run → finish` like the sibling's runner,
which is eight lines and gets the engine, both limits and the recording switch
at once.

**One defect the switch surfaced.** The report read `engine.time` and
`engine.stop_reason` — fields of the sequential engine. A parallel engine keeps
its clock as `frontier_time`, so the first parallel run finished the simulation
and then threw on the report. It reads `simulation_time(execution)` and
`simulation_stop_reason(execution)` now, which answer the same way whichever
engine ran.

**Check — done.** `ActiveSourcePassiveSink` run on each engine writes scalar
files that are identical line for line, apart from the moment, the process id
and the result directory. The suite is 188 tests green, with threads and
without.

### Phase 3 — the editor executable

Written by `plan/pending/executable-with-user-interface.md` phase 3. When it
lands, it inherits every option above, because they live in the runner's reader.
It adds only the sibling's `--width` and `--height`, and the capture rule for a
parallel run.

### Phase 4 — the documentation

- [x] `package/runner/doc/runner.md` — the option table, the thread rule, and
      why the run walks the pipeline.
- [ ] Move this plan to `plan/done/` — after phase 3, which belongs to the
      other plan.

## 6. Tests

- [x] Each new option, its default, and its refusal, in
      `package/runner/test/command_line.jl` — 188 green.
- [x] A run with `--result-recording=false` leaves no result file. Checked by
      hand rather than asserted: the suite's run tests each name a result
      directory, and asserting an absence there would assert the temporary
      directory more than the option.
- [ ] The two-engine comparison of phase 2, in `package/runner/test`.

## 7. Out of scope

- **A parameter override on the command line.** The sibling's §3.5, and
  `plan/done/native-simulation-binary.md` §10 already refused it here.
- **A parameter study.** §3.2.
- **`opp_run`'s `--parsim-*` options.** A different mechanism.
