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

### Phase 0 — wait for the sibling

- [ ] `omnetpp-julia`'s plan, phase 1. It defines `--engine`, `--workers`, the
      thread refusal and the `--build-info` rows.
- [ ] `run_network!` takes an `engine` keyword (§4).

Both are changes in `omnetpp-julia`, and the `[sources]` of this repository
reach that repository's **main checkout**, so neither is usable here until it
lands on `main`.

### Phase 1 — the five options

- [ ] `Options` gains `sim_time_limit`, `cpu_time_limit`, `express_mode` and
      `result_recording`, with the sibling's types and defaults.
- [ ] `parse_command_line` reads all five, refuses `--record-eventlog=true`,
      and refuses a second `-f` (§3.1).
- [ ] `run_options` honours them: the limit wins over the configuration's, the
      recorder is not attached when recording is off, and no result file is
      written then.
- [ ] The help text lists them.

**Check.** The reference run of `plan/done/native-simulation-binary.md` phase 6
writes the same scalars it recorded, and `--result-recording=false` writes no
file at all.

### Phase 2 — the engine

- [ ] `--engine=` and `--workers=`, read by the same code the sibling uses.
- [ ] `check_engine` — the thread refusal.
- [ ] `run_options` passes the spec to `run_network!`.
- [ ] `--build-info` prints the thread count and the default engine.

**Check.** One queueing configuration run on each engine, and the two scalar
files compared. They must differ only in the moment, the process id and the
result directory. If they differ anywhere else, the engine moved the answer and
that is a defect in the engine, not in this plan.

### Phase 3 — the editor executable

Written by `plan/pending/executable-with-user-interface.md` phase 3. When it
lands, it inherits every option above, because they live in the runner's reader.
It adds only the sibling's `--width` and `--height`, and the capture rule for a
parallel run.

### Phase 4 — the documentation

- [ ] `package/runner/doc/runner.md` — the option table and the thread rule.
- [ ] Move this plan to `plan/done/`.

## 6. Tests

- [ ] Each new option, its default, and its refusal, in
      `package/runner/test/command_line.jl`.
- [ ] A run with `--result-recording=false` leaves no result file.
- [ ] The two-engine comparison of phase 2, in `package/runner/test`.

## 7. Out of scope

- **A parameter override on the command line.** The sibling's §3.5, and
  `plan/done/native-simulation-binary.md` §10 already refused it here.
- **A parameter study.** §3.2.
- **`opp_run`'s `--parsim-*` options.** A different mechanism.
