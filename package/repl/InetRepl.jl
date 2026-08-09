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
# See plan/pending/package-convention-repl-leaves.md.
# ═══════════════════════════════════════════════════════════════════════════

module InetRepl

using PrecompileTools: @setup_workload, @compile_workload
using Preferences: @load_preference, set_preferences!

using Inet
using InetExample
using InetTest
using ProjecturedSdl

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

How much this build compiled ahead of time: `:none`, `:minimal`, `:demo` or
`:full`. Read as a preference at module scope, so the precompile cache depends
on it and changing it rebuilds. An environment variable would not — the stale
image would be reused and the setting would quietly do nothing.
"""
const WORKLOAD = Symbol(@load_preference("workload", "minimal"))

"""
    set_workload!(level::Symbol) -> level

Choose how much the next build compiles, then restart Julia. `:none` for a day
spent editing the model, `:demo` when the editor is what is being shown.
"""
function set_workload!(level::Symbol)
    level in (:none, :minimal, :demo, :full) ||
        error("set_workload!: level must be :none, :minimal, :demo or :full, got ",
              repr(level))
    set_preferences!(@__MODULE__, "workload" => String(level); force = true)
    @info "workload level set — restart Julia for it to take effect" level
    level
end

export WORKLOAD, set_workload!

@setup_workload begin
    @compile_workload begin
        InetExample.precompile_workload(WORKLOAD)
    end
end

end # module InetRepl
