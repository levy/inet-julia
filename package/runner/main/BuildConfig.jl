# ============================================================================
# What the build chose, read back at run time.
#
# `tool/build_binary.jl` takes parameters. Three of them describe the program
# rather than the run — the name it answers to, how much it compiled ahead of
# time, and the processor it was compiled for — and a run has to be able to
# state them. This is where they arrive.
#
# A preference, and not a constant in a generated source file. A preference
# read at module scope is recorded as a dependency of the precompile cache, so
# a build at another level rebuilds; a generated file that the module includes
# only when it exists is not noticed when it appears, and the stale image is
# reused with the old level silently inside it. `InetRepl.WORKLOAD` is the same
# mechanism for a session, and this is it for an executable.
#
# Read at module scope, so the value is compiled into the image. The built
# executable reads no TOML file and needs none beside it.
#
# A checkout where no build has run answers the defaults below, which is what
# `bin/inet-julia` runs on.
# ============================================================================

"""
    BuildConfigModule

The build parameters that describe the program: [`APP_NAME`](@ref),
[`APP_WORKLOAD`](@ref) and [`APP_CPU_TARGET`](@ref).
"""
module BuildConfigModule

using Preferences: @load_preference

export APP_NAME, APP_WORKLOAD, APP_CPU_TARGET

"""
    APP_NAME

The name this build answers to. It is the first word of every message, of the
help text and of the banner a run prints, so a person who pastes a log knows
which program wrote it.

`inet-julia` is the command-line build. `inet-julia-editor` is the build that
also draws.
"""
const APP_NAME = @load_preference("name", "inet-julia")

"""
    APP_WORKLOAD

How much this build compiled ahead of time: `:none`, `:minimal`, `:demo` or
`:full`. `tool/binary_precompile.jl` reads it and runs that much.

The four levels are the ones `InetRepl.set_workload!` uses for a session. One
vocabulary, two places that spend build time.
"""
const APP_WORKLOAD = Symbol(@load_preference("workload", "demo"))

"""
    APP_CPU_TARGET

Which processor the image was compiled for. An empty string is
PackageCompiler's own default, which runs on any x86-64 machine and therefore
on none of them well.

Nothing reads this but the report. It is here so a bundle can say what it is.
"""
const APP_CPU_TARGET = @load_preference("cpu_target", "")

end # module BuildConfigModule
