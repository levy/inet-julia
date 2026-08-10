"""
    InetRunner

The command-line runner: `inet-julia -f omnetpp.ini -c TestNetwork -r 0`.

One configuration, one run, two result files, no user interface. The package
the `inet-julia` executable is built from, by `tool/build_binary.jl`.

The dependency list in `Project.toml` is a contract — the editor must not be
reachable from here. `InetRunnerTest.test_runner_closure()` asserts it, and
`plan/done/native-simulation-binary.md` §2 says why.

Reached from Julia as well as from a command line:

    using InetRunner
    InetRunner.main(["-f", "omnetpp.ini", "-c", "TestNetwork", "-r", "0"])
"""
module InetRunner

# What the build chose, before the command line that reports it.
include("BuildConfig.jl")
include("CommandLine.jl")
include("ResultFiles.jl")
include("NedIni.jl")
include("Runner.jl")

using .BuildConfigModule
using .CommandLineModule
using .ResultFilesModule
using .NedIni
using .RunnerModule

export main, julia_main

"""
    INTERFACES

The user interfaces this package holds: `:cmdenv`, and nothing else.

This is a fact about the package, not a build parameter. A runner draws nothing
because it depends on nothing that draws, so no build of *this* package can
hold `:editor`. `InetRunnerEditor` holds both, and that is why it is a second
package.
"""
const INTERFACES = (:cmdenv,)

"""
    main(arguments; io = stdout) -> Cint

Read the arguments, run what they describe, and answer the exit code: 0 the run
finished, 1 the command line is wrong, 2 the run failed.

Every error stops here. A runner is driven by scripts, so an exit code and one
line on stderr are its whole error report — a stack trace would be noise in a
log of a thousand runs.
"""
function main(arguments::AbstractVector{<:AbstractString}; io::IO = stdout)
    options = try
        parsed = parse_command_line(arguments)
        if parsed isa Options
            check_interface(parsed.user_interface, INTERFACES)
            check_engine(parsed)
        end
        parsed
    catch exception
        exception isa CommandLineError || rethrow()
        println(stderr, "$PROGRAM_NAME: $(exception.message)")
        return Cint(1)
    end
    options === :help && (print(io, help_text(INTERFACES)); return Cint(0))
    options === :version && (println(io, version_text()); return Cint(0))
    options === :build_info && (print(io, build_info_text(INTERFACES)); return Cint(0))
    try
        return run_options(options; io = io)
    catch exception
        println(stderr, "$PROGRAM_NAME: $(sprint(showerror, exception))")
        return Cint(2)
    end
end

"""
    julia_main() -> Cint

The entry point `create_app` builds the executable around. It reads `ARGS`,
because that is what an executable is handed.
"""
julia_main() = main(ARGS)

end # module InetRunner
