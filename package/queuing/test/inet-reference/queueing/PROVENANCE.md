# Provenance of the reference `.sca` / `.vec` files in this directory

These files are the unmodified `omnetpp` result output of running the two
`inet-cpp` QueueingTutorial configurations `ActiveSourcePassiveSink` and
`PacketQueue`, captured as reference data for the Julia queuing migration
(Phase 0). Nothing under `inet-cpp` or `omnetpp-cpp` was edited to produce
them.

## Date

2026-08-08

## Repository state

- `inet-cpp` commit: `b52bc21a34ca893afc8567ee3c297ff3512d3dbc` (branch `master`), working tree clean (`git status --short` empty).
- `omnetpp-cpp` commit: `008fc03a0510df98db017e174c2069d03c7c115a`, working tree clean (`git status --short` empty).
- Build mode: **release** (`out/clang-release/`, `bin/inet` picked up `libINET.so` from `out/clang-release/src` via the `src/libINET.so` hardlink, launched through `opp_run_release`).

## OMNeT++ version

Output of `../../bin/inet -v` (after sourcing both `setenv` scripts, see below):

```
OMNeT++ Discrete Event Simulation  (C) 1992-2025 Andras Varga, OpenSim Ltd.
Version: 6.4.0, build: internal, edition: Academic Public License -- NOT FOR COMMERCIAL USE
See the license for distribution terms and warranty disclaimer

Setting up Cmdenv...

Build: omnetpp-6.4.0 internal
Compiler: CLANG 23.0.0 (++20260325083105+68994554ea12-1~exp1~20260325203127.404)
Options: 64-bit ARCH_X86_64 RELEASE WITH_NETBUILDER WITH_PYTHON
```

## Environment setup and a required workaround

Both `setenv` scripts were sourced normally, from their own directories:

```
cd /home/projectured/workspace/omnetpp-cpp && source setenv -q
cd /home/projectured/workspace/inet-cpp    && source setenv -q
```

Neither `setenv` script sets `LD_LIBRARY_PATH`. The OMNeT++ binaries
(`opp_run_release` etc.) were built with a hard-coded `DT_RUNPATH` of
`/home/projectured/workspace/omnetpp:.:/home/projectured/workspace/omnetpp/tools/linux.x86_64/lib`
(confirmed with `readelf -d`) — i.e. they expect the OMNeT++ checkout to live
at `.../workspace/omnetpp`, but it actually lives at
`.../workspace/omnetpp-cpp` in this environment. No `workspace/omnetpp`
directory/symlink exists, so running `bin/inet` unmodified failed with:

```
/home/projectured/workspace/omnetpp-cpp/bin/opp_run_release: error while loading shared libraries: liboppcmdenv.so: cannot open shared object file: No such file or directory
```

This is a pre-existing linker-path mismatch in the prebuilt `omnetpp-cpp`
binaries, not something introduced here. It was worked around by exporting
`LD_LIBRARY_PATH` to point at the real lib directory before invoking `inet`
(the dynamic loader consults `LD_LIBRARY_PATH` before `DT_RUNPATH`, so this
takes precedence without touching any file):

```
export LD_LIBRARY_PATH="/home/projectured/workspace/omnetpp-cpp/lib:$LD_LIBRARY_PATH"
```

No file under `inet-cpp` or `omnetpp-cpp` was modified to achieve this.

## Exact commands run

```
cd /home/projectured/workspace/omnetpp-cpp
source setenv -q

cd /home/projectured/workspace/inet-cpp
source setenv -q

export LD_LIBRARY_PATH="/home/projectured/workspace/omnetpp-cpp/lib:$LD_LIBRARY_PATH"

cd /home/projectured/workspace/inet-cpp/tutorials/queueing

../../bin/inet -u Cmdenv -c ActiveSourcePassiveSink
../../bin/inet -u Cmdenv -c PacketQueue
```

Both runs completed in well under a second of wall-clock time (`real 0m0.157s`
and `real 0m0.159s` respectively), hitting `sim-time-limit = 10s` at event #12
and event #26 respectively, with no warnings or errors.

## Files captured

Copied verbatim (byte-for-byte, no post-processing) from
`inet-cpp/tutorials/queueing/results/` into this directory, keeping their
original names:

- `ActiveSourcePassiveSink-#0.sca`
- `ActiveSourcePassiveSink-#0.vec`
- `PacketQueue-#0.sca`
- `PacketQueue-#0.vec`

The companion `.vci` (vector index) files were *not* copied — they are a
regeneratable index over the `.vec` files, not additional data.

Total copied size: 54,871 bytes (4 files, ~53.6 KiB).

Run IDs (also the value of the `run` line in each result file):

- `ActiveSourcePassiveSink-0-20260808-11:35:28-178086`
- `PacketQueue-0-20260808-11:35:28-178106`
