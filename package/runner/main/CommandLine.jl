# ============================================================================
# The command line — the arguments the `inet-julia` executable accepts, turned
# into one value the runner reads.
#
# Nothing here names INET, a model, a network or an element. The runner's
# second consumer is a simulation that is not INET, and when it arrives this
# file moves down to `OmnetppDescription` unchanged
# (plan/done/native-simulation-binary.md §4.3).
# ============================================================================

"""
    CommandLineModule

Reads the arguments of the `inet-julia` command into [`Options`](@ref).

The option set is `opp_run`'s, cut to what one run of one configuration needs:
`-f`, `-c`, `-r`, `-n`, `-u`, `--result-dir=`, `-h` and `-v`. An option outside
that set is an error and not a silence — an ignored `--sim-time-limit`
produces a run that is wrong in a way no output shows.
"""
module CommandLineModule

using OmnetppFormat: parse_omnetpp_quantity, omnetpp_quantity_seconds

using ..BuildConfigModule: APP_NAME, APP_WORKLOAD, APP_CPU_TARGET

export Options, CommandLineError, parse_command_line, help_text, version_text,
    build_info_text, check_interface, interface_symbol, interface_name,
    engine_symbol, engine_name, ENGINES,
    ned_directories, PROGRAM_NAME, PROGRAM_VERSION

# What the build named this program. Every message starts with it, so the two
# executables this repository builds cannot be confused in a log.
const PROGRAM_NAME = APP_NAME
const PROGRAM_VERSION = "0.1.0"

"""
    CommandLineError(message)

A command line that cannot be read. The entry point prints the message on
stderr and exits 1.
"""
struct CommandLineError <: Exception
    message::String
end

Base.showerror(io::IO, e::CommandLineError) = print(io, e.message)

"""
    Options

One command line, read.

`run` is 1-based, because everything below the command line is
(`CLAUDE.md`). The command line itself is 0-based, because `opp_run` is.
[`parse_command_line`](@ref) is the only place the two meet.

An empty `ned_path` means the default, which depends on the INI file and is
therefore resolved by [`ned_directories`](@ref) rather than here.
"""
struct Options
    # Which user interface runs this: `:cmdenv` writes result files and draws
    # nothing, `:editor` opens a window. What a build holds is the build's
    # business, not this reader's — see [`check_interface`](@ref).
    user_interface::Symbol
    # Which engine runs it: `:sequential` or `:parallel`. An execution degree of
    # freedom — it decides how the answer is computed and never what the answer
    # is, which is the invariant the two engines' equal hashes assert.
    engine::Symbol
    # How many worker threads the parallel engine runs, or `nothing` for its
    # own default. Meaningless for the sequential engine, which is why naming
    # it there is refused.
    workers::Union{Nothing,Int}
    ini_files::Vector{String}
    config::String
    run::Int
    ned_path::Vector{String}
    result_dir::String
    # In seconds, and `nothing` means the command line named none. A
    # `sim_time_limit` given here wins over the one the configuration states; a
    # configuration states no CPU limit at all.
    sim_time_limit::Union{Nothing,Float64}
    cpu_time_limit::Union{Nothing,Float64}
    express_mode::Bool
    # false ⇒ no recorder at all, and therefore no scalars, no vectors, no
    # statistics and no result files. It is the cheapest a run gets, and it is
    # what a speed measurement wants.
    result_recording::Bool
end

"""
    ned_directories(options) -> Vector{String}

The directories to look for `.ned` files in. With no `-n`, that is the
directory the first INI file sits in.
"""
ned_directories(options::Options) =
    isempty(options.ned_path) ? [dirname(abspath(first(options.ini_files)))] :
                                options.ned_path

"""
    interface_symbol(name) -> Symbol

The `-u` name a person writes, as the symbol everything below uses: `Cmdenv`
answers `:cmdenv`, and `Editor` answers `:editor`.

`Qtenv` is refused by name rather than accepted as a second spelling. Qtenv is
a C++ program built on Qt. The editor here is neither, and a script that asks
for one and gets the other has been told something untrue.
"""
function interface_symbol(name::AbstractString)
    name == "Cmdenv" && return :cmdenv
    name == "Editor" && return :editor
    name == "Qtenv" &&
        throw(CommandLineError("there is no Qtenv here — the names are Cmdenv " *
                               "and Editor, and the one that draws is Editor"))
    throw(CommandLineError("unknown user interface '$name' — the names are " *
                           "Cmdenv and Editor"))
end

"""
    interface_name(interface) -> String

The `-u` name of a symbol, for a help text and for an error message.
"""
interface_name(interface::Symbol) = interface === :cmdenv ? "Cmdenv" : "Editor"

"""
    check_interface(interface, held) -> nothing

Refuse a user interface this build does not hold.

`held` is the entry package's own list. `InetRunner` holds `(:cmdenv,)` and
cannot hold more: it depends on nothing that draws, and
`InetRunnerTest.test_runner_closure()` is what keeps that true.
"""
function check_interface(interface::Symbol, held)
    interface in held && return nothing
    throw(CommandLineError("$(interface_name(interface)) is not in this build — " *
                           "$PROGRAM_NAME holds " *
                           "$(join(interface_name.(held), " and ")) and draws " *
                           "nothing. The build that draws is inet-julia-editor, " *
                           "from `tool/build_binary.jl --editor`."))
end

"""
    ENGINES

The engines a command line can name. `sequential` runs the events in order on
one thread. `parallel` colours the event horizon and runs the green events on
worker threads, which needs a process started with threads.
"""
const ENGINES = (:sequential, :parallel)

"""
    engine_symbol(name) -> Symbol

The `--engine` name a person writes, as the symbol everything below uses.

`parsim` is refused by name. OMNeT++ parallelises by partitioning a network
across processes that exchange null messages; this engine runs one process and
colours the event horizon. They are different mechanisms with different failure
modes.
"""
function engine_symbol(name::AbstractString)
    name == "sequential" && return :sequential
    name == "parallel" && return :parallel
    name in ("parsim", "parsim-mpi", "parsim-namedpipe") &&
        throw(CommandLineError("there is no parsim here — this engine runs one " *
                               "process and colours the event horizon. The names " *
                               "are $(join(ENGINES, " and "))"))
    throw(CommandLineError("unknown engine '$name' — the names are " *
                           "$(join(ENGINES, " and "))"))
end

"""
    engine_name(engine) -> String

The `--engine` name of a symbol, for a help text and for a report.
"""
engine_name(engine::Symbol) = String(engine)

version_text() = "$PROGRAM_NAME $PROGRAM_VERSION"

"""
    build_info_text(held; extra = []) -> String

What the build chose, as a block of `name value` lines. `--build-info` prints
it.

`--version` says which program this is, and this says what went into it. The
two are separate because a run prints the version line as its banner, and a
reference test compares run output line for line.

`extra` is where an entry package that holds more than the command line does —
the backends it compiled in, the entry it opens — adds its own rows.
"""
function build_info_text(held; extra = Pair{String,String}[])
    rows = Pair{String,String}[
        "name" => PROGRAM_NAME,
        "version" => PROGRAM_VERSION,
        "interfaces" => join(interface_name.(held), ", "),
    ]
    append!(rows, extra)
    append!(rows, [
        "workload" => String(APP_WORKLOAD),
        "cpu target" => isempty(APP_CPU_TARGET) ? "portable" : APP_CPU_TARGET,
        "julia" => string(VERSION),
        # What the parallel engine has to work with. A thread count cannot be
        # asked for on the command line — this program's arguments never reach
        # Julia's own option reader — so it is read from JULIA_NUM_THREADS
        # before any of this runs, and this is the only place that says what it
        # got.
        "threads" => string(Threads.nthreads()),
    ])
    width = maximum(length(first(row)) for row in rows)
    join(("$(rpad(first(row), width))  $(last(row))" for row in rows), "\n") * "\n"
end

"""
    help_text(held = (:cmdenv,); extra = "") -> String

The help this build prints. `held` decides which `-u` names it offers, and
`extra` is where an entry package that has options of its own puts them — a
build that draws accepts `--backend` and `--catalog`, and one that does not
must not offer them.
"""
help_text(held = (:cmdenv,); extra::AbstractString = "") = """
Usage: $PROGRAM_NAME [options]

Runs one configuration of one simulation and writes its result files.

  -f <file>            the INI file; repeatable (default: omnetpp.ini)
  -c <name>            the configuration name (default: General)
  -r <n>               the run number, counted from 0 (default: 0)
  -n <path>            NED directories, separated by ':'
                       (default: the directory of the INI file)
  -u <name>            the user interface: $(join(interface_name.(held), " or "))
  --engine=<name>      the engine: $(join(ENGINES, " or ")) (default: sequential)
  --workers=<n>        worker threads for the parallel engine
  --result-dir=<dir>   where the result files go (default: results)
  --sim-time-limit=<t> stop at this simulation time; overrides the
                       configuration's own limit
  --cpu-time-limit=<t> stop after this much wall-clock time
  --cmdenv-express-mode=<b>  accepted; this runner is always express
  --result-recording=<b>     false turns off every recorder: no scalars, no
                             vectors, no statistics, no result files
  --record-eventlog=<b>      accepted only as false; no event log is written
  -h, --help           print this text and exit
  -v, --version        print the version and exit
  --build-info         print what this build was made with and exit$extra

Exit codes: 0 the run finished, 1 the command line is wrong, 2 the run failed.
"""

# The text after the `=` of a `--name=value` argument.
_assigned(argument, name) = argument[length(name) + 2:end]

# A time an option states: `100s`, `250000s`, `1000ms`, or a bare number of
# seconds. The reader of the INI file understands the same spellings, which is
# the point — one option and one file must not mean two different things.
function _time_value(text, option)
    isempty(text) && throw(CommandLineError("$option needs a time"))
    quantity = parse_omnetpp_quantity(text)
    if quantity !== nothing
        seconds = omnetpp_quantity_seconds(text)
        seconds === nothing &&
            throw(CommandLineError("$option needs a time, got '$text'"))
        return seconds
    end
    number = tryparse(Float64, text)
    number === nothing &&
        throw(CommandLineError("$option needs a time, got '$text'"))
    number
end

function _boolean_value(text, option)
    text == "true" && return true
    text == "false" && return false
    throw(CommandLineError("$option needs true or false, got '$text'"))
end

# The argument of an option that takes one. `index` points at the option
# itself, so the value is the argument after it.
function _value_of(arguments, index, option)
    index < length(arguments) ||
        throw(CommandLineError("$option needs a value"))
    arguments[index + 1]
end

"""
    parse_command_line(arguments) -> Options | :help | :version

Read the arguments. Answers `:help` or `:version` when the command line asks
only for a text, and throws [`CommandLineError`](@ref) when it cannot be read.
"""
function parse_command_line(arguments::AbstractVector{<:AbstractString};
                            default_interface::Symbol = :cmdenv)
    user_interface = default_interface
    engine = :sequential
    workers = nothing
    ini_files = String[]
    config = "General"
    run_number = 0
    ned_path = String[]
    result_dir = "results"
    sim_time_limit = nothing
    cpu_time_limit = nothing
    express_mode = true
    result_recording = true

    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        if argument == "-h" || argument == "--help"
            return :help
        elseif argument == "-v" || argument == "--version"
            return :version
        elseif argument == "--build-info"
            return :build_info
        elseif argument == "-f"
            # `opp_run` layers several INI files over one another. This runner
            # reads one, so a second is refused rather than dropped — a rule
            # from a file that was accepted and never read is the failure this
            # option set exists to prevent. `omnetpp-julia` refuses it too.
            isempty(ini_files) ||
                throw(CommandLineError("only one INI file is read, and " *
                                       "'$(first(ini_files))' is already it — " *
                                       "layering several is not implemented"))
            push!(ini_files, _value_of(arguments, index, "-f"))
            index += 2
        elseif argument == "-c"
            config = _value_of(arguments, index, "-c")
            index += 2
        elseif argument == "-r"
            text = _value_of(arguments, index, "-r")
            number = tryparse(Int, text)
            number === nothing &&
                throw(CommandLineError("-r needs a whole number, got '$text'"))
            number >= 0 ||
                throw(CommandLineError("-r counts from 0, got $number"))
            run_number = number
            index += 2
        elseif argument == "-n"
            append!(ned_path, split(_value_of(arguments, index, "-n"), ':'; keepempty = false))
            index += 2
        elseif argument == "-u"
            user_interface = interface_symbol(_value_of(arguments, index, "-u"))
            index += 2
        # Neither `--engine` nor `--workers` is recorded anywhere a result reads.
        # An execution degree of freedom must not change what the run recorded,
        # and a header line is part of what the run recorded.
        elseif startswith(argument, "--engine=")
            engine = engine_symbol(_assigned(argument, "--engine"))
            index += 1
        elseif startswith(argument, "--workers=")
            text = _assigned(argument, "--workers")
            number = tryparse(Int, text)
            number === nothing &&
                throw(CommandLineError("--workers needs a whole number, got '$text'"))
            number >= 1 ||
                throw(CommandLineError("--workers counts from 1, got $number"))
            workers = number
            index += 1
        elseif startswith(argument, "--sim-time-limit=")
            sim_time_limit = _time_value(_assigned(argument, "--sim-time-limit"),
                                         "--sim-time-limit")
            index += 1
        elseif startswith(argument, "--cpu-time-limit=")
            cpu_time_limit = _time_value(_assigned(argument, "--cpu-time-limit"),
                                         "--cpu-time-limit")
            index += 1
        elseif startswith(argument, "--cmdenv-express-mode=")
            express_mode = _boolean_value(_assigned(argument, "--cmdenv-express-mode"),
                                          "--cmdenv-express-mode")
            index += 1
        elseif startswith(argument, "--result-recording=")
            result_recording = _boolean_value(_assigned(argument, "--result-recording"),
                                              "--result-recording")
            index += 1
        elseif startswith(argument, "--record-eventlog=")
            # There is no event log to turn off, so the only answer this runner
            # can honour is the one that asks for none.
            _boolean_value(_assigned(argument, "--record-eventlog"),
                           "--record-eventlog") &&
                throw(CommandLineError("--record-eventlog=true is not available — " *
                                       "$PROGRAM_NAME writes no event log"))
            index += 1
        elseif startswith(argument, "--result-dir=")
            result_dir = argument[length("--result-dir=") + 1:end]
            isempty(result_dir) &&
                throw(CommandLineError("--result-dir= needs a directory"))
            index += 1
        elseif argument in ("--result-dir", "--sim-time-limit", "--cpu-time-limit",
                            "--cmdenv-express-mode", "--result-recording",
                            "--record-eventlog", "--engine", "--workers")
            throw(CommandLineError("write $argument=<value>, with the '='"))
        elseif startswith(argument, "-")
            throw(CommandLineError("unknown option '$argument' — " *
                                   "run $PROGRAM_NAME -h for the ones that exist"))
        else
            throw(CommandLineError("unexpected argument '$argument' — " *
                                   "every value belongs to an option"))
        end
    end

    isempty(ini_files) && push!(ini_files, "omnetpp.ini")
    # The command line counts runs from 0 and everything below it counts from
    # 1. This is the one line where that is true.
    # A worker count the engine cannot use is refused rather than dropped: the
    # sequential engine has no workers, so a number that does nothing here
    # would be a lie no output shows.
    engine === :sequential && workers !== nothing &&
        throw(CommandLineError("--workers is for the parallel engine, and this " *
                               "run is sequential — write --engine=parallel too"))

    Options(user_interface, engine, workers, ini_files, config, run_number + 1,
            ned_path, result_dir, sim_time_limit, cpu_time_limit, express_mode,
            result_recording)
end

end # module CommandLineModule
