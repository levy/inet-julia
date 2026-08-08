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

export Options, CommandLineError, parse_command_line, help_text, version_text,
    ned_directories, PROGRAM_NAME, PROGRAM_VERSION

const PROGRAM_NAME = "inet-julia"
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

version_text() = "$PROGRAM_NAME $PROGRAM_VERSION"

help_text() = """
Usage: $PROGRAM_NAME [options]

Runs one configuration of one simulation and writes its result files.

  -f <file>            the INI file; repeatable (default: omnetpp.ini)
  -c <name>            the configuration name (default: General)
  -r <n>               the run number, counted from 0 (default: 0)
  -n <path>            NED directories, separated by ':'
                       (default: the directory of the INI file)
  -u <name>            the user interface; only Cmdenv is accepted
  --result-dir=<dir>   where the result files go (default: results)
  -h, --help           print this text and exit
  -v, --version        print the version and exit

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
function parse_command_line(arguments::AbstractVector{<:AbstractString})
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
            name = _value_of(arguments, index, "-u")
            name == "Cmdenv" ||
                throw(CommandLineError("only Cmdenv is available, not '$name' — " *
                                       "$PROGRAM_NAME draws nothing"))
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
    Options(ini_files, config, run_number + 1, ned_path, result_dir)
end

end # module CommandLineModule
