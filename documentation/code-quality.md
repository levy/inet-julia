# Code quality

How the code of this repository reads, and what keeps it readable. A human reads
this code to learn what it does. Every rule here serves that reader.

The rules that hold in all three repositories are in
`omnetpp-team/policy/code-quality-rules.md`. Read them first. This document adds
what is true here: the shape of a file, the local rules, the size budgets, and
the measured baseline. It never weakens a shared rule.

## What this document does not cover

| Subject | Owner |
| --- | --- |
| Names of packages, files, modules, and simulation elements | [omnetpp-julia/documentation/naming.md](../../omnetpp-julia/documentation/naming.md) |
| Names in the editing vocabulary | [the kernel naming document](../../projectured-julia/package/kernel/doc/naming.md) |
| What belongs in which package | [packages.md](packages.md) |
| What this repository promises | [requirements.md](requirements.md) |
| What every change must respect | [architecture-requirements.md](architecture-requirements.md) |

**This repository has no naming document of its own.** The two above are the
authority. `omnetpp-julia/documentation/naming.md` §3 covers the case that is
specific here: an element takes the NED type name, and becomes `StemModule` only
where a role interface already took the plain name, which is where the elements
of this repository are.

## 1. The shape of a file

**A file opens with a box comment that states its job and its reason.** 142
files of 212 carry one, the strongest header habit of the three repositories.

```julia
# ============================================================================
# A queuing network as a model the lifecycle can run: the canonical chain of
# source, queue, server and sink, with its parameters exposed as degrees of
# freedom so the workbench can sweep them.
#
# This is the demonstration that the queuing elements are a model library and
# not just a set of parts ...
# ============================================================================
```

The second paragraph is the part worth keeping. It says why the file exists at
all, not only what it holds.

**Import a named list.** The form here is `using <Package>.<Module>: names`,
because the dependency is a package rather than a sibling file:

```julia
using OmnetppSimulator.NetworkModule: Network, add_module!, connect_gates!
```

**A section banner is rare here** — 51 in 19 files. The files are smaller, so
most do not need one. Add one when a file passes about 300 lines.

## 2. Local rules

**A model answers the lifecycle, and nothing below it knows which elements it
holds.** `QueuingModel.jl` is the model of this: the four questions the engine
asks are forwarded to the `Network`, so the model does not name its parts twice.
Keep it that way when you add a model.

**The topology comes from the wiring the engine reads.** `model_topology` reads
the same `Network` the run uses, so a diagram can not drift from the model it
describes. Do not build a second description of a network for a view.

**A comment states the modelling choice.** The queuing model says that a
capacity uses a dropper rather than back pressure, and that this is what makes
it an M/M/1/K queue. A reader who knows queuing theory can then check the code
against the theory. This is the most valuable comment in this repository, and
there should be more of it.

**Check parity against `inet-cpp`.** A protocol is right when a run matches, not
when it compiles. `inet-cpp` is a read-only reference.

**A sealed file is frozen.** [SEALING.md](../SEALING.md) holds the list.

## 3. The open quality problem: test file names

48 test files are named after the migration phase that produced them, not after
what they test:

```
package/packet/test/phase22_wave4.jl
package/packet/test/phase20_wave2b.jl
package/packet/test/phase12_draft.jl
package/linklayer/test/...
```

The count is 25 in `packet`, 17 in `linklayer`, and 6 in `queuing`. The other
two repositories have none.

This breaks the naming rule that binds all three repositories: a name says what
the thing is, not when it arrived. A reader who wants the tests of a chunk
header can not find them. A name such as `phase20_wave2b.jl` records a schedule
that no longer exists.

Some of these names carry a subject as well — `phase3_headers.jl`,
`phase5_tags.jl`, `phase15_options.jl` — and those are a rename away from being
right. Others carry nothing but the schedule.

This is the first thing the code quality steward must propose here. It is a
rename of test files only, so it changes no behaviour, and a suite proves it at
once. It needs the approval of the human before it starts.

## 4. Size budgets

| Thing | Today | Budget |
| --- | --- | --- |
| Line width | median 42, 90% under 78, 95% under 80 | 90 characters |
| A main-code function | median 7 lines, 90% under 21, longest 131 | 60 lines |
| A file | mean 239 lines, 10 over 500 | 500 lines |

This is the tidiest of the three repositories by every size measurement. The
longest hand-written files are `package/packet/main/protocol/Sctp.jl` at 1091
lines and `package/linklayer/main/t1s/PlcaFsm.jl` at 820.

`package/repl/PrecompileStatements.jl` is generated. No rule applies to it.

## 5. The measured baseline

Reproduce these with the commands in
`omnetpp-team/policy/code-quality-rules.md`.

| Measurement | 2026-08-14 |
| --- | --- |
| Julia files | 212, mean 239 lines |
| Main-code function blocks | 370, mean 11 lines |
| Export statements | 59 |
| Docstrings | about 741 |
| Comment lines | 5564 |
| Comment lines with a history word or a marker | 13 |
| Imports: blanket against named | 254 against 318 |
| Private helpers with a leading underscore | 247 |
| Section banners | 51 in 19 files |
| Box headers | 142 |
| Inline field comments | 76 |
| Files over 500 lines, generated file excluded | 10 |
| File names that carry a schedule instead of a subject | 48 |

Two numbers stand out. The file names are the worst of the three repositories.
Everything else is the best of the three.

## 6. Where this repository differs from the other two

| Point | Here | projectured-julia | omnetpp-julia |
| --- | --- | --- | --- |
| File header | `# ====` box, 142 files | `# Fragment of` line, 63 files | `# ====` box, 149 files |
| Section banner | 51 | 1451 | 523 |
| Requirement prefix | `IR-`, `IAR-` | `PAR-`, `PR-` | `OR-`, `OAR-`, `OB-`, `RISK-`, `REJ-` |
| Sealed file list | `SEALING.md` | `CLAUDE.md` | `SEALING.md` |
| Naming authority | the other two | its own kernel document | its own document |

## 7. How this document is used

The code quality steward audits a slice when its plan moves to `plan/done/`. It
measures first, then reads the files that the plan touched, then writes a reader
report: every place where its understanding broke, with the file and the line.

The steward proposes. The human accepts a new rule into this document. No large
cleanup starts before that.
