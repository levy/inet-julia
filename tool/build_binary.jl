# ============================================================================
# Build the `inet-julia` executable.
#
#     julia --project=tool tool/build_binary.jl
#
# The output is `build/inet-julia/`, a directory that holds the executable, a
# system image and the shared libraries they need. Copy it to a machine with no
# Julia on it and run `bin/inet-julia`.
#
# PackageCompiler and not juliac: `juliac --trim` forbids dynamic dispatch, and
# the element library dispatches on module type at every gate
# (plan/pending/native-simulation-binary.md §4.1).
# ============================================================================

using Pkg
using PackageCompiler

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SOURCE = joinpath(ROOT, "package", "runner", "main")
const TARGET = joinpath(ROOT, "build", "inet-julia")

# `create_app` reads the app's own Manifest, and a Manifest is gitignored here,
# so a fresh checkout has none.
@info "Resolving $SOURCE"
let tool_project = Base.active_project()
    Pkg.activate(SOURCE)
    Pkg.instantiate()
    Pkg.activate(tool_project)
end

@info "Building $TARGET"
create_app(SOURCE, TARGET;
           executables = ["inet-julia" => "julia_main"],
           precompile_execution_file = joinpath(@__DIR__, "binary_precompile.jl"),
           include_lazy_artifacts = true,
           force = true)

# The three numbers plan/pending/native-simulation-binary.md phase 4 asks to be
# recorded. Measure them here, so they are measured the same way every time.
size_bytes = parse(Int, split(read(`du -sb $TARGET`, String))[1])
@info "Built" size_MB = round(size_bytes / 1024^2; digits = 1)

executable = joinpath(TARGET, "bin", "inet-julia")
start = time()
run(pipeline(`$executable --version`; stdout = devnull))
@info "Started" version_seconds = round(time() - start; digits = 2)

println("""

Built. Try it:

    $executable -c Queuing --result-dir=/tmp/inet-julia-results
""")
