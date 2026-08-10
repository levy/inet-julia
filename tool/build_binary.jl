# ============================================================================
# Build an executable of this repository.
#
#     julia --project=tool tool/build_binary.jl                  # inet-julia
#     julia --project=tool tool/build_binary.jl --editor         # and a window
#     julia --project=tool tool/build_binary.jl --workload=none --cpu-target=native
#
# The output is `build/<name>/`, a directory that holds the executable, a system
# image and the shared libraries they need. The name follows the interfaces the
# build holds, so the two executables never overwrite each other:
#
#     build/inet-julia/bin/inet-julia
#     build/inet-julia-editor/bin/inet-julia-editor
#
# This file is the front end. `tool/Build.jl` is the builder, and every flag
# here is one of its keywords — call it directly from a REPL when a spec is
# easier to write than a command line.
# ============================================================================

using Pkg

# This environment's own Manifest is gitignored too, so a fresh checkout has
# none and `using PackageCompiler` inside the builder would fail. Resolve
# before naming anything that is not a standard library.
Pkg.instantiate()

include(joinpath(@__DIR__, "Build.jl"))
using .InetBuild

const USAGE = """
Usage: julia --project=tool tool/build_binary.jl [options]

Builds one executable of this repository. With no option it builds the
command-line executable, which is what it built before it took any option.

  --editor                   hold the user interface as well as the command
                             line: -u Cmdenv runs, -u Editor draws
  --interfaces=a,b           the interfaces to hold (cmdenv, editor)
  --default-interface=name   what -u means when a command line omits it
  --name=<name>              the executable name, and the directory under build/
  --backends=a,b             the display backends to compile in (sdl)
  --default-backend=name     the one a run with no --backend uses
  --expose-backend           accept --backend at run time
  --entry=catalog|none       what opens when a command line names no
                             configuration
  --catalog=<dir>            read the catalog from this directory
  --workload=<level>         how much to compile ahead of time:
                             none, minimal, demo, full
  --cpu-target=<target>      the processor to compile for; 'native' is about
                             twice as fast and runs on this machine alone
  --output=<dir>             where the bundle goes (default: build/<name>)
  --log=<file>               send the compile output to a file
  --no-compile               write the parameters, print the spec, and stop
  -h, --help                 print this text and exit

The processor target also reads INET_CPU_TARGET, the environment-variable
spelling of --cpu-target. `omnetpp-julia` reads OMNETPP_CPU_TARGET the same
way.
"""

_after(argument, name) = argument[length(name) + 2:end]
_list(text) = Symbol.(split(text, ','; keepempty = false))

function parse_build_arguments(arguments)
    keywords = Dict{Symbol,Any}()
    output = nothing
    logfile = nothing
    compile = true
    for argument in arguments
        if argument == "-h" || argument == "--help"
            print(USAGE)
            exit(0)
        elseif argument == "--editor"
            keywords[:interfaces] = [:cmdenv, :editor]
        elseif startswith(argument, "--interfaces=")
            keywords[:interfaces] = _list(_after(argument, "--interfaces"))
        elseif startswith(argument, "--default-interface=")
            keywords[:default_interface] = Symbol(_after(argument, "--default-interface"))
        elseif startswith(argument, "--name=")
            keywords[:name] = _after(argument, "--name")
        elseif startswith(argument, "--backends=")
            keywords[:backends] = _list(_after(argument, "--backends"))
        elseif startswith(argument, "--default-backend=")
            keywords[:default_backend] = Symbol(_after(argument, "--default-backend"))
        elseif argument == "--expose-backend"
            keywords[:expose_backend_flag] = true
        elseif startswith(argument, "--entry=")
            keywords[:entry] = Symbol(_after(argument, "--entry"))
        elseif startswith(argument, "--catalog=")
            keywords[:catalog] = _after(argument, "--catalog")
        elseif startswith(argument, "--workload=")
            keywords[:workload] = Symbol(_after(argument, "--workload"))
        elseif startswith(argument, "--cpu-target=")
            keywords[:cpu_target] = _after(argument, "--cpu-target")
        elseif startswith(argument, "--output=")
            output = _after(argument, "--output")
        elseif startswith(argument, "--log=")
            logfile = _after(argument, "--log")
        elseif argument == "--no-compile"
            compile = false
        else
            println(stderr, "build_binary: unknown option '$argument'")
            println(stderr)
            print(stderr, USAGE)
            exit(1)
        end
    end
    (keywords, output, logfile, compile)
end

let (keywords, output, logfile, compile) = parse_build_arguments(ARGS)
    spec = BuildSpec(; keywords...)
    build_binary(spec;
                 compile = compile,
                 logfile = logfile,
                 (output === nothing ? () : (; output = output))...)
end
