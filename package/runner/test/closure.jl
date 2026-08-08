# ============================================================================
# The guard — the editor must not be reachable from the executable.
#
# A runner writes result files. It draws nothing, opens no window and reads no
# gesture, so 65268 lines of syntax, widget, layout and domain code have no
# business in its image. This is the only thing that holds that rule
# (plan/done/native-simulation-binary.md §2).
#
# The walk is static — `[deps]` followed through `[sources]`, project file by
# project file — because a resolved Manifest belongs to an environment and the
# rule belongs to the package.
#
# The `Revise` assertion is red against `omnetpp-julia` main. It found a real
# defect on its first run: `OmnetppSimulator` declared Revise in `[deps]` and
# no source file used it. The fix is committed on that repository's `binary`
# branch ("A development tool is not a dependency of the engine"), and this
# turns green when that branch lands. Revise is declared in exactly one project
# file of the whole closure, so nothing else has to change.
# ============================================================================
using Test
using TOML

const RUNNER_MAIN = normpath(joinpath(@__DIR__, "..", "main"))

# What must never be reachable, and what each one would drag in.
const FORBIDDEN = [
    "ProjecturedVisual" => "syntax, text, widget, layout, font and colour",
    "ProjecturedDomain" => "the domains, Markdown and Base64",
    "Projectured"       => "the umbrella, which names both of the above",
    "OmnetppLegacy"     => "the projections and the C++ launcher",
    "DataFrames"        => "the result reader, which the runner does not use",
    "Revise"            => "a development tool",
]

# What must be reachable, so that an empty walk cannot pass the test.
const REQUIRED = ["InetQueuing", "OmnetppSimulator", "ProjecturedKernel", "ProjecturedBase"]

"""
    dependency_closure(project_dir) -> Set{String}

Every package name reachable from the project in `project_dir`, following
`[sources]` paths as far as they go. A dependency with no `[sources]` entry is
a registry package or a standard library: its name is collected, and the walk
stops there.
"""
function dependency_closure(project_dir::AbstractString)
    names = Set{String}()
    visited = Set{String}()
    pending = [normpath(project_dir)]
    while !isempty(pending)
        directory = pop!(pending)
        directory in visited && continue
        push!(visited, directory)
        project = TOML.parsefile(joinpath(directory, "Project.toml"))
        sources = get(project, "sources", Dict{String,Any}())
        for name in keys(get(project, "deps", Dict{String,Any}()))
            push!(names, name)
            source = get(sources, name, nothing)
            source isa AbstractDict && haskey(source, "path") &&
                push!(pending, normpath(joinpath(directory, source["path"])))
        end
    end
    names
end

@testset "the executable carries no editor" begin
    closure = dependency_closure(RUNNER_MAIN)

    # The walk reached something. Without this a broken walk passes every
    # assertion below by finding nothing at all.
    for name in REQUIRED
        @test name in closure
    end

    for (name, what) in FORBIDDEN
        @test !(name in closure)
        name in closure &&
            @info "InetRunner reaches $name — it would put $what in the executable"
    end
end
