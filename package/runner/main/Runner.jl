# ============================================================================
# The runner — one command line, one run, two result files.
#
# It reads the two files, builds the network they describe, runs it, and
# reports what happened. Nothing here parses NED or INI: `OmnetppDescription`
# does that, and `NedIni.jl` beside this file says which Julia type each NED
# type name means.
# ============================================================================

"""
    RunnerModule

Runs the simulation one [`Options`](@ref) describes.
"""
module RunnerModule

using Dates: now

using OmnetppSimulator: run_network!, Recorder, attach_sink!, close_sinks!,
    OmnetppTextSink, total_event_count, stop_reason_text, fmt_time
using OmnetppFormat: nedparse_file, NedCompoundModule
using OmnetppDescription: read_ini_configuration, ParameterResolution,
    build_ned_network, unused_rules
using InetQueuing.PacketProtocolModule: check_packet_connections

using ..CommandLineModule: Options, PROGRAM_NAME, version_text, ned_directories
using ..ResultFilesModule: scalar_file_path, vector_file_path, result_run_name,
    result_run_attributes
using ..NedIni: register_queuing_ned_types!

export run_options, RunFailure, ned_file_declaring

"""
    RunFailure(message)

A command line that reads correctly but describes a run that cannot be made.
The entry point prints the message on stderr and exits 2.
"""
struct RunFailure <: Exception
    message::String
end

Base.showerror(io::IO, e::RunFailure) = print(io, e.message)

# ── Finding the NED file ─────────────────────────────────────────────────────

# Every `.ned` file under the NED path, in a stable order, so two runs of one
# command line read the same file when two of them declare the same network.
function _ned_files(directories)
    found = String[]
    for directory in directories
        isdir(directory) || throw(RunFailure("no such NED directory: $directory"))
        for (root, _, files) in walkdir(directory), file in files
            endswith(file, ".ned") && push!(found, joinpath(root, file))
        end
    end
    sort!(found)
end

"""
    ned_file_declaring(directories, network) -> (path, parsed)

The `.ned` file that declares `network`, and its parsed tree.

The name has to appear in the text before the file is worth parsing. INET has
1672 `.ned` files and a NED path may point at all of them; parsing every one to
find a name that is in one of them would cost more than the run.
"""
function ned_file_declaring(directories, network::AbstractString)
    files = _ned_files(directories)
    isempty(files) &&
        throw(RunFailure("no .ned file under " * join(directories, ", ")))
    for path in files
        occursin(network, read(path, String)) || continue
        parsed = nedparse_file(path)
        any(child -> child isa NedCompoundModule && child.name == network,
            parsed.children) && return (path, parsed)
    end
    throw(RunFailure("no .ned file declares network '$network' — " *
                     "looked in $(length(files)) file(s) under " *
                     join(directories, ", ")))
end

# ── The run ──────────────────────────────────────────────────────────────────

# The reader fails with error types of its own, and each one already names the
# construct and where it is. Turn them into a RunFailure so `main` reports one
# line and exits 2, rather than a stack trace that a log of a thousand runs
# would drown in.
function _describing(body, action::AbstractString)
    try
        body()
    catch exception
        exception isa RunFailure && rethrow()
        throw(RunFailure("$action: $(sprint(showerror, exception))"))
    end
end

"""
    run_options(options; io = stdout) -> Cint

Run what `options` describes, and answer the exit code. Throws
[`RunFailure`](@ref) when the description cannot be made into a run.
"""
function run_options(options::Options; io::IO = stdout)
    register_queuing_ned_types!()

    run_number = options.run - 1        # reported the way the user wrote it
    run_number == 0 ||
        throw(RunFailure("run #$run_number does not exist — a configuration " *
                         "fans out into one run until a parameter study does " *
                         "otherwise, so 0 is the only run number"))

    ini_path = first(options.ini_files)
    isfile(ini_path) || throw(RunFailure("no such INI file: $ini_path"))

    println(io, version_text())

    configuration = _describing("reading $ini_path") do
        read_ini_configuration(ini_path, options.config)
    end
    resolution = ParameterResolution(configuration)

    ned_path, parsed = ned_file_declaring(ned_directories(options), configuration.network)
    println(io, "Preparing configuration $(options.config), run #$run_number.")
    println(io, "Network $(configuration.network), from $ned_path.")

    network = _describing("building $(configuration.network)") do
        build_ned_network(parsed, configuration.network, resolution)
    end

    # A rule that matched nothing is a typo in the INI file, and a typo that
    # silently changes nothing is the worst kind. Say so, and run anyway — the
    # user asked for a run and not for a lint.
    for rule in unused_rules(resolution)
        println(io, "Warning: no parameter matched $(rule.key).")
    end

    # The moment and the process id go into the run name, so two runs of one
    # configuration are told apart by their header and not only by their path.
    moment = now()
    process_id = getpid()
    mkpath(options.result_dir)
    scalar_path = scalar_file_path(options.result_dir, options.config, run_number)
    vector_path = vector_file_path(options.result_dir, options.config, run_number)

    recorder = Recorder()
    attach_sink!(recorder,
        OmnetppTextSink(vector_path;
            sca_path = scalar_path,
            run_name = result_run_name(options.config, run_number, moment, process_id),
            run_attributes = result_run_attributes(
                config = options.config, run_number = run_number,
                network = configuration.network,
                moment = moment, process_id = process_id, ini_file = ini_path),
            # A recorder keeps scalars in one flat namespace, so an element
            # writes its module path into the name. OMNeT++ keeps the two in
            # separate columns, and this reads the name back into them.
            split_module_path = true))

    println(io, "Running the simulation.")
    engine = run_network!(network; until = configuration.sim_time_limit,
                          recorder = recorder, check = check_packet_connections)
    # Nothing above is a lifecycle execution, so nothing closes the sinks on
    # our behalf. The files are written here or not at all.
    close_sinks!(recorder; at = engine.time)

    println(io, "Finished: t=$(fmt_time(engine.time)), $(total_event_count(engine)) events, " *
                "$(stop_reason_text(engine.stop_reason)).")
    println(io, "Results: $scalar_path")
    println(io, "         $vector_path")
    Cint(0)
end

end # module RunnerModule
