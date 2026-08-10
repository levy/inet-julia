# ============================================================================
# The builder — what `tool/build_binary.jl` is a front end for.
#
#     include("tool/Build.jl")           # julia --project=tool
#     using .InetBuild
#     build_binary(runner_binary())      # the command-line executable
#     build_binary(editor_binary())      # the one that also draws
#     build_binary(; interfaces = [:cmdenv, :editor], workload = :demo,
#                    name = "omnetpp-demo")
#
# A `BuildSpec` says what goes into the binary. The keywords of `build_binary`
# say where it goes and how noisy the build is. The split is deliberate: two
# builds that differ only in `output` produce the same program, and two that
# differ in the spec do not.
#
# PackageCompiler and not juliac: `juliac --trim` forbids dynamic dispatch, and
# the engine dispatches on module type at every gate while `NetworkModel`
# reaches its builder through a registry
# (plan/done/native-executable-runner.md §4.1).
# ============================================================================

"""
    InetBuild

The parameters of a build, and the build.

See `plan/pending/executable-with-user-interface.md`.
"""
module InetBuild

import Pkg
using Preferences: set_preferences!

export BuildSpec, build_binary, runner_binary, editor_binary, build_preferences,
    entry_project, spec_text, validate

const ROOT = normpath(joinpath(@__DIR__, ".."))
const RUNNER_PROJECT = joinpath(ROOT, "package", "runner", "main")
const EDITOR_PROJECT = joinpath(ROOT, "package", "runner", "editor")

# The one configuration this repository can run end to end, and it lives in the
# `inet-cpp` checkout beside this one. A machine that builds the executable
# need not have it, so every use of this is guarded.
const TUTORIAL = normpath(joinpath(ROOT, "..", "inet-cpp", "tutorials", "queueing"))

"The user interfaces a build can hold."
const INTERFACES = (:cmdenv, :editor)

"The display backends a build can compile in."
const BACKENDS = (:sdl,)

"What the editor opens when the command line names no configuration."
const ENTRIES = (:catalog, :none)

"""
    WORKLOADS

How much a build compiles ahead of time. The four levels
`InetRepl.set_workload!` uses for a session, so one vocabulary covers both
places that spend build time.

| level | the simulation half | the editor half |
| --- | --- | --- |
| `:none` | nothing | nothing |
| `:minimal` | the paths that answer without running, one NED file, one INI file | every tier's atoms |
| `:demo` | and the whole grammar corpus, and one whole run | and their stub walks |
| `:full` | and the recording run, and the parameter study | and one catalog page, opened and forced |

`:full` is the default, because it is what the build did before it took any
parameter, and a build with no flag must not quietly ship less than it shipped
yesterday.
"""
const WORKLOADS = (:none, :minimal, :demo, :full)

# ── The spec ─────────────────────────────────────────────────────────────────

"""
    BuildSpec(; interfaces = [:cmdenv], name, default_interface, backends,
                default_backend, expose_backend_flag, entry, catalog,
                workload, cpu_target)

What goes into the binary.

Every keyword has a default, and most of the defaults follow `interfaces`: a
build that holds `:editor` is named `inet-julia-editor`, compiles SDL in,
and opens the catalog when the command line names no configuration. A build
that holds only `:cmdenv` is named `inet-julia` and compiles no backend.

Both compile at `:full`, which is what the build did before it took any
parameter at all.

| keyword | default | meaning |
| --- | --- | --- |
| `interfaces` | `[:cmdenv]` | which user interfaces the binary holds |
| `name` | from `interfaces` | the executable name, and the directory under `build/` |
| `default_interface` | `:editor` when held, else `:cmdenv` | what `-u` means when the command line omits it |
| `backends` | `[:sdl]` when `:editor` is held | the display backends compiled in |
| `default_backend` | first of `backends` | the one a run with no `--backend` uses |
| `expose_backend_flag` | `length(backends) > 1` | whether the binary accepts `--backend` |
| `entry` | `:catalog` | what opens when the command line names no configuration |
| `catalog` | `nothing` (the bundled one) | which directory the catalog is read from |
| `workload` | `:full` | how much the build compiles ahead of time |
| `cpu_target` | `""` (portable) | `"native"` is about twice as fast, on this machine only |
"""
struct BuildSpec
    name::String
    interfaces::Vector{Symbol}
    default_interface::Symbol
    backends::Vector{Symbol}
    default_backend::Union{Symbol,Nothing}
    expose_backend_flag::Bool
    entry::Symbol
    catalog::Union{String,Nothing}
    workload::Symbol
    cpu_target::String
end

"""
    default_name(interfaces) -> String

The executable name a set of interfaces gets when nobody names one. This is
what keeps two builds out of each other's directory.
"""
default_name(interfaces) =
    :editor in interfaces ? "inet-julia-editor" : "inet-julia"

function BuildSpec(; interfaces::AbstractVector = [:cmdenv],
                     name::AbstractString = default_name(interfaces),
                     default_interface::Symbol =
                         :editor in interfaces ? :editor : :cmdenv,
                     backends::AbstractVector =
                         :editor in interfaces ? [:sdl] : Symbol[],
                     default_backend::Union{Symbol,Nothing} =
                         isempty(backends) ? nothing : Symbol(first(backends)),
                     expose_backend_flag::Bool = length(backends) > 1,
                     entry::Symbol = :catalog,
                     catalog::Union{AbstractString,Nothing} = nothing,
                     workload::Symbol = :full,
                     cpu_target::AbstractString = get(ENV, "INET_CPU_TARGET", ""))
    spec = BuildSpec(String(name), Symbol.(collect(interfaces)), default_interface,
                     Symbol.(collect(backends)), default_backend,
                     expose_backend_flag, entry,
                     catalog === nothing ? nothing : abspath(catalog),
                     workload, String(cpu_target))
    validate(spec)
    spec
end

"""
    validate(spec) -> spec

Refuse a spec that describes no program. Every check here is one a build would
otherwise fail at minute six, or worse, not fail at and produce a binary that
cannot do what its name says.
"""
function validate(spec::BuildSpec)
    isempty(spec.name) && error("BuildSpec: `name` must not be empty")
    isempty(spec.interfaces) && error("BuildSpec: `interfaces` must not be empty")
    for interface in spec.interfaces
        interface in INTERFACES ||
            error("BuildSpec: :$interface is not a user interface; the names are $INTERFACES")
    end
    spec.default_interface in spec.interfaces ||
        error("BuildSpec: default interface :$(spec.default_interface) is not in " *
              "interfaces $(spec.interfaces)")
    for backend in spec.backends
        backend in BACKENDS ||
            error("BuildSpec: :$backend is not a backend; the names are $BACKENDS")
    end
    if :editor in spec.interfaces
        isempty(spec.backends) &&
            error("BuildSpec: a build that holds :editor needs a backend to draw on")
        spec.default_backend in spec.backends ||
            error("BuildSpec: default backend :$(spec.default_backend) is not in " *
                  "backends $(spec.backends)")
    else
        isempty(spec.backends) ||
            error("BuildSpec: backends $(spec.backends) are asked for, and this build " *
                  "holds no :editor to draw with them")
    end
    spec.entry in ENTRIES ||
        error("BuildSpec: entry :$(spec.entry) is not one of $ENTRIES")
    spec.catalog === nothing || isdir(spec.catalog) ||
        error("BuildSpec: no such catalog directory: $(spec.catalog)")
    spec.workload in WORKLOADS ||
        error("BuildSpec: workload :$(spec.workload) is not one of $WORKLOADS")
    spec
end

"""
    runner_binary(; kwargs...) -> BuildSpec

The command-line executable: one configuration, one run, two result files, no
window. What the build made before it took a parameter.
"""
runner_binary(; kwargs...) = BuildSpec(; interfaces = [:cmdenv], kwargs...)

"""
    editor_binary(; kwargs...) -> BuildSpec

The executable that also draws: the same runs under `-u Cmdenv`, and a window
under `-u Editor`.
"""
editor_binary(; kwargs...) = BuildSpec(; interfaces = [:cmdenv, :editor], kwargs...)

"""
    entry_project(spec) -> String

The package the executable is built from: `package/runner/main` for a build
that only runs, and `package/runner/editor` for one that also draws.
"""
entry_project(spec::BuildSpec) =
    :editor in spec.interfaces ? EDITOR_PROJECT : RUNNER_PROJECT

"""
    precompile_file(spec) -> String

What the build runs so the image holds compiled code.

Two files and not one with a branch in it: the editor's half of a workload
names packages that a command-line build does not have, and a trace that
mentions them would not load there.
"""
precompile_file(spec::BuildSpec) =
    joinpath(@__DIR__, :editor in spec.interfaces ? "editor_precompile.jl" :
                                                    "binary_precompile.jl")

# ── The parameters, handed to the program ────────────────────────────────────

"""
    build_preferences(spec; project = entry_project(spec)) -> String

Write the spec into the entry project's `LocalPreferences.toml`, and answer the
path.

A preference and not a generated source file, because the precompile cache
depends on a preference: a build at another workload level rebuilds, and a
build under another name rebuilds. The value is read at module scope, so it
ends up compiled into the image and the bundle needs no TOML file beside it.

**Every build writes every key.** A build that wrote only the keys it changed
would leave the last build's answer for the rest, and that answer would then be
compiled into this binary.
"""
function build_preferences(spec::BuildSpec; project::AbstractString = entry_project(spec))
    toml = joinpath(project, "LocalPreferences.toml")
    set_preferences!(toml, "InetRunner",
                     "name" => spec.name,
                     "workload" => String(spec.workload),
                     "cpu_target" => spec.cpu_target;
                     force = true)
    if :editor in spec.interfaces
        set_preferences!(toml, "InetRunnerEditor",
                         "default_interface" => String(spec.default_interface),
                         "backends" => String[String(b) for b in spec.backends],
                         "default_backend" => String(something(spec.default_backend, :sdl)),
                         "expose_backend" => spec.expose_backend_flag,
                         "entry" => String(spec.entry),
                         "catalog" => spec.catalog === nothing ? "" : spec.catalog;
                         force = true)
    end
    toml
end

"""
    spec_text(spec) -> String

The spec as the lines `--build-info` prints. The build says what it is about to
make, in the words the binary itself will use.
"""
function spec_text(spec::BuildSpec)
    rows = Pair{String,String}[
        "name" => spec.name,
        "interfaces" => join(String.(spec.interfaces), ", "),
        "default interface" => String(spec.default_interface),
    ]
    if :editor in spec.interfaces
        push!(rows, "backends" => join(String.(spec.backends), ", ") *
                                  (spec.expose_backend_flag ? " (--backend accepted)" :
                                                              " (baked in)"))
        push!(rows, "entry" => String(spec.entry))
        push!(rows, "catalog" => spec.catalog === nothing ? "the bundled one" : spec.catalog)
    end
    push!(rows, "workload" => String(spec.workload))
    push!(rows, "cpu target" => isempty(spec.cpu_target) ? "portable" : spec.cpu_target)
    width = maximum(length(first(row)) for row in rows)
    join(("$(rpad(first(row), width))  $(last(row))" for row in rows), "\n") * "\n"
end

# ── The build ────────────────────────────────────────────────────────────────

"""
    build_binary(spec; output, compile = true, force = true, logfile = nothing) -> String
    build_binary(; kwargs...)

Build the executable `spec` describes. Answers the output directory, or the
`LocalPreferences.toml` path when `compile = false`.

`compile = false` writes the parameters and stops. It costs no minutes, and it
is how a test asserts what a spec turns into.

`logfile` sends the long, noisy compile output to a file. The default leaves it
where an interactive caller can see it.

The caller's active environment is restored on the way out: the build has to
activate the app project, and a REPL session must not be left in it.
"""
function build_binary(spec::BuildSpec;
                      output::AbstractString = joinpath(ROOT, "build", spec.name),
                      compile::Bool = true, force::Bool = true,
                      logfile::Union{AbstractString,Nothing} = nothing)
    # Absolute, because the report runs the executable from the tutorial's own
    # directory and a relative path does not survive the change of directory.
    output = abspath(output)
    project = entry_project(spec)
    isdir(project) ||
        error("build_binary: the entry package for $(spec.interfaces) is not " *
              "written yet — no such directory: $project")
    preferences = build_preferences(spec; project = project)
    @info "build_binary: wrote $preferences\n" * spec_text(spec)
    compile || return preferences

    logfile === nothing && return _compile!(spec, project, output, force)
    mkpath(dirname(abspath(logfile)))
    @info "build_binary: compiling — output goes to $(abspath(logfile))"
    open(logfile, "w") do io
        redirect_stdout(io) do
            redirect_stderr(io) do
                _compile!(spec, project, output, force)
            end
        end
    end
end

build_binary(; kwargs...) = build_binary(BuildSpec(; kwargs...))

function _compile!(spec::BuildSpec, project, output, force)
    # `create_app` reads the app's own Manifest, and a Manifest is gitignored
    # here, so a fresh checkout has none.
    @info "Resolving $project"
    let tool_project = Base.active_project()
        try
            Pkg.activate(project)
            Pkg.instantiate()
        finally
            tool_project === nothing || Pkg.activate(tool_project; io = devnull)
        end
    end

    @info "Building $output" name = spec.name workload = spec.workload cpu_target =
        isempty(spec.cpu_target) ? "portable (default)" : spec.cpu_target
    _create_app(project, output;
                executables = [spec.name => "julia_main"],
                precompile_execution_file = precompile_file(spec),
                include_lazy_artifacts = true,
                force = force,
                (isempty(spec.cpu_target) ? () : (; cpu_target = spec.cpu_target))...)
    report(spec, output)
    output
end

# PackageCompiler is loaded by the one step that compiles, and not at the top of
# this module. A spec is also read where no compiler is installed — the test
# package includes this file to assert what a spec turns into, and a test must
# not drag a compiler in to do it.
#
# Loaded by its identity rather than with `@eval import`: an import at run time
# creates a binding in this module in a later world than the code that reads
# it, which Julia 1.12 warns about and a later Julia will refuse.
const PACKAGE_COMPILER =
    Base.PkgId(Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"), "PackageCompiler")

function _create_app(args...; kwargs...)
    Base.invokelatest(getfield(Base.require(PACKAGE_COMPILER), :create_app),
                      args...; kwargs...)
end

"""
    report(spec, output) -> nothing

The three numbers every build records: the size of the bundle, the time
`--version` takes, and the time one whole run takes.

Measured here, so they are measured the same way every time.
"""
function report(spec::BuildSpec, output::AbstractString)
    size_bytes = parse(Int, split(read(`du -sb $output`, String))[1])
    @info "Built" size_MB = round(size_bytes / 1024^2; digits = 1)

    executable = joinpath(output, "bin", spec.name)
    start = time()
    run(pipeline(`$executable --version`; stdout = devnull))
    @info "Started" version_seconds = round(time() - start; digits = 2)

    # One whole run of one configuration, so the number is a run and not only a
    # start. Every build holds `:cmdenv`, so this number is comparable across
    # every spec.
    #
    # The configuration lives in the `inet-cpp` checkout, which a machine that
    # builds this need not have. Say when it is missing rather than fail the
    # build over a measurement.
    if isdir(TUTORIAL)
        mktempdir() do results
            start = time()
            cd(TUTORIAL) do
                run(pipeline(`$executable -u Cmdenv -c ActiveSourcePassiveSink -r 0
                              --result-dir=$results`; stdout = devnull))
            end
            @info "Ran ActiveSourcePassiveSink" run_seconds =
                round(time() - start; digits = 2)
        end
    else
        @info "No run measured: $TUTORIAL is not there (the inet-cpp checkout)"
    end

    println("""

    Built. Try it, in a directory that holds a NED file and an INI file:

        $executable -u Cmdenv -c <Config> -r 0
    """)
    :editor in spec.interfaces && println("""    and, for a window:

        $executable -u Editor -c <Config>
        $executable
    """)
    nothing
end

end # module InetBuild
