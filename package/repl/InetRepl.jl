# ═══════════════════════════════════════════════════════════════════════════
# InetRepl — the leaf a person loads to work in this repository.
#
# A package image is built with exactly that package's dependencies present, so
# compiled code survives only in a package that nothing depends on and nothing
# loads after. This is that package.
#
#     julia --project=. -e 'using Revise, InetRepl'
#
# Revise stays in the alias rather than in the dependencies: it has to be loaded
# before the packages it tracks, and as a dependency its position in the load
# order is the resolver's business.
#
# What this build compiles is `WORKLOAD`. The default replays a recording rather
# than running a workload, because a workload only compiles what somebody thought
# to run and nobody thought to read: the first click on `PacketIsChunks.md` costs
# 42 ms replaying a recording and 1691 ms running the workload.
#
# See plan/pending/package-convention-repl-leaves.md and
# projectured-julia's plan/pending/recorded-precompile-workload.md.
# ═══════════════════════════════════════════════════════════════════════════

module InetRepl

using PrecompileTools: @setup_workload, @compile_workload
using Preferences: @load_preference, set_preferences!

using Inet
using InetExample
using InetTest
using ProjecturedSdl
# Not re-exported: the recording machinery is reached by name.
import ProjecturedExample

# Everything the packages export is exported again, so one `using` at the prompt
# gives the session a person expects.
for _module in (Inet, InetExample, InetTest, ProjecturedSdl)
    for _name in names(_module)
        _name === nameof(_module) && continue
        @eval export $_name
    end
end

"""
    WORKLOAD

How this build compiled ahead of time: `:none`, `:recorded` or `:live`. Read as a
preference at module scope, so the precompile cache depends on it and changing it
rebuilds. An environment variable would not — the stale image would be reused and
the setting would quietly do nothing.
"""
const WORKLOAD = Symbol(@load_preference("workload", "recorded"))

const WORKLOAD_LEVELS = (:none, :recorded, :live)

"""
    set_workload!(level::Symbol) -> level

Choose how the next build compiles, then restart Julia.

| level | what the build does |
| --- | --- |
| `:none` | nothing; for a day spent editing the model |
| `:recorded` | replays [`PRECOMPILE_STATEMENTS`](@ref) — the default |
| `:live` | runs `InetExample.precompile_workload()` |

`:recorded` is the default. A recording covers what a person actually did rather
than what somebody thought to write down, which is why it is the only one of the
three that compiles the *reader*: measured in omnetpp-julia, the read half of a
first click is 4.4 ms under `:recorded` and 528 ms under `:live`, the same as
under no workload at all.

It costs a checked-in list that has to be re-recorded as the code moves — see
[`record_precompile_statements`](@ref). The list goes stale gracefully, and
`:live` is what to choose when a build must not depend on a file.
"""
function set_workload!(level::Symbol)
    level in WORKLOAD_LEVELS ||
        error("set_workload!: level must be one of ", WORKLOAD_LEVELS, ", got ",
              repr(level))
    set_preferences!(@__MODULE__, "workload" => String(level); force = true)
    @info "workload level set — restart Julia for it to take effect" level
    level
end

export WORKLOAD, get_workload, set_workload!

"""
    get_workload() -> Symbol

The level **this session was built with** — the same value as [`WORKLOAD`](@ref),
as a function, so it pairs with [`set_workload!`](@ref).

It also answers the question `WORKLOAD` cannot: whether the level stored for the
next build still matches the one in this image. `set_workload!` writes a
preference and a preference only takes effect on a rebuild, so a session where
the two differ is a session that has not been restarted yet, and this says so.
"""
function get_workload()
    stored = Symbol(@load_preference("workload", "recorded"))
    if stored !== WORKLOAD
        @warn "this session was built with another level; restart to pick the stored one up" built=WORKLOAD stored=stored
    end
    WORKLOAD
end

# ── the recording ──────────────────────────────────────────────────────────
#
# The machinery is `ProjecturedExample`'s, shared with the other repositories'
# leaves. What belongs here is what only this repository knows: which run to
# record, and the list that run produced.

include("PrecompileStatements.jl")

"""
    StatementScope

Where a recorded statement is resolved. It is a module of *this* package because
`replay_precompile_statements` binds every loaded module into it by name, and
binding names into a dependency's module while this one precompiles would be one
build writing into another package's image.
"""
module StatementScope end

"""
    replay_precompile_statements(; warn = true) -> (compiled, skipped, total)

Compile every statement of this repository's recording that still names
something. Called by the build; call it at the prompt to see what the list is
worth without a rebuild.
"""
replay_precompile_statements(; warn::Bool = true) =
    ProjecturedExample.replay_precompile_statements(PRECOMPILE_STATEMENTS,
                                                    StatementScope; warn = warn)

"""
    record_precompile_statements(; output, driver, kwargs...) -> path

Drive this repository's demo catalog and the registered examples under
`--trace-compile`, and write the list this package replays. Needs a display: the
driver opens a real window, so that what it records is the whole stack down to
SDL.
"""
record_precompile_statements(;
        output::AbstractString = joinpath(@__DIR__, "PrecompileStatements.jl"),
        driver::AbstractString = joinpath(@__DIR__, "record", "driver.jl"),
        kwargs...) =
    ProjecturedExample.record_precompile_statements(driver, output; kwargs...)

export PRECOMPILE_STATEMENTS, replay_precompile_statements,
       record_precompile_statements

@setup_workload begin
    @compile_workload begin
        WORKLOAD === :recorded && replay_precompile_statements()
        WORKLOAD === :live && InetExample.precompile_workload()
    end
end

end # module InetRepl
