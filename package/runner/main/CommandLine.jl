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

using ..BuildConfigModule: APP_NAME, APP_WORKLOAD, APP_CPU_TARGET

export Options, CommandLineError, parse_command_line, help_text, version_text,
    build_info_text, check_interface, interface_symbol, interface_name,
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
    ini_files::Vector{String}
    config::String
    run::Int
    ned_path::Vector{String}
    result_dir::String
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
  --result-dir=<dir>   where the result files go (default: results)
  -h, --help           print this text and exit
  -v, --version        print the version and exit
  --build-info         print what this build was made with and exit$extra

Exit codes: 0 the run finished, 1 the command line is wrong, 2 the run failed.
"""

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
    ini_files = String[]
    config = "General"
    run_number = 0
    ned_path = String[]
    result_dir = "results"

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
        elseif startswith(argument, "--result-dir=")
            result_dir = argument[length("--result-dir=") + 1:end]
            isempty(result_dir) &&
                throw(CommandLineError("--result-dir= needs a directory"))
            index += 1
        elseif argument == "--result-dir"
            throw(CommandLineError("write --result-dir=<dir>, with the '='"))
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
    Options(user_interface, ini_files, config, run_number + 1, ned_path, result_dir)
end

end # module CommandLineModule
