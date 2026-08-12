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

import OmnetppSimulator
using OmnetppSimulator: Recorder, attach_sink!, close_sinks!,
    OmnetppTextSink, total_event_count, stop_reason_text, fmt_time,
    make_prebuilt_network_instance, make_execution,
    run_execution!, finish_execution!, simulation_engine, simulation_time,
    simulation_stop_reason,
    simulation_limit, NO_LIMIT,
    EngineSpec, SequentialEngineSpec, ParallelEngineSpec, engine_min_threads,
    engine_startable
using OmnetppFormat: nedparse_file, NedCompoundModule
using OmnetppDescription: read_ini_configuration, ParameterResolution,
    build_ned_network, unused_rules
using InetQueuing.PacketProtocolModule: check_packet_connections

using ..CommandLineModule: Options, CommandLineError, PROGRAM_NAME, version_text,
    ned_directories
using ..ResultFilesModule: scalar_file_path, vector_file_path, result_run_name,
    result_run_attributes
using ..NedIni: register_queuing_ned_types!

export run_options, RunFailure, ned_file_declaring, engine_spec, check_engine,
    engine_text, run_limit

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

    # `--result-recording=false` means no recorder at all, and therefore no
    # scalars, no vectors and no files. It is the cheapest a run gets.
    recording = options.result_recording
    moment = now()
    process_id = getpid()
    scalar_path = ""
    vector_path = ""
    recorder = nothing
    if recording
        # The moment and the process id go into the run name, so two runs of one
        # configuration are told apart by their header and not only by their path.
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
    end

    # Which engine, before "Running the simulation", because it is a fact about
    # the run that follows. The sequential engine says nothing, so the output of
    # a run that names no engine is the output it always was.
    spec = engine_spec(options)
    text = engine_text(spec)
    isempty(text) || println(io, text)

    println(io, "Running the simulation.")
    # The pipeline and not `run_network!`. The shorthand takes a simulation time
    # and this runner has to carry a wall-clock limit as well, which only a
    # whole `SimulationLimit` expresses — and the two verbs are the same six
    # steps either way.
    # Initializing here rather than leaving it to a builder: this model is made
    # from a tree that already exists, and the check wants an initialized
    # network before it starts.
    OmnetppSimulator.NetworkModule.initialize_network!(network)
    check_packet_connections(network)
    execution = make_execution(make_prebuilt_network_instance(network);
        engine = spec,
        record = recording, recorder = recorder,
        limit = run_limit(options, configuration, io))
    run_execution!(execution)
    finish_execution!(execution)
    engine = simulation_engine(execution)
    # Nothing above is a lifecycle execution, so nothing closes the sinks on
    # our behalf. The files are written here or not at all.
    recorder === nothing || close_sinks!(recorder; at = simulation_time(execution))

    # The execution's clock and stop reason, not the engine's own fields: a
    # parallel engine keeps its frontier under another name, and a report must
    # read the same way whichever engine ran.
    println(io, "Finished: t=$(fmt_time(simulation_time(execution))), " *
                "$(total_event_count(engine)) events, " *
                "$(stop_reason_text(simulation_stop_reason(execution))).")
    if recording
        println(io, "Results: $scalar_path")
        println(io, "         $vector_path")
    else
        println(io, "Results: none — recording is off.")
    end
    Cint(0)
end

"""
    run_limit(options, configuration, io) -> SimulationLimit

How far the run goes: what `--sim-time-limit` said, else what the configuration
says, plus whatever `--cpu-time-limit` said. A user interface needs the same
answer a run needs, so the rule lives here and not in each of them.
"""
function run_limit(options::Options, configuration, io::IO)
    sim_time = options.sim_time_limit === nothing ? configuration.sim_time_limit :
                                                    options.sim_time_limit
    if sim_time === nothing && options.cpu_time_limit === nothing
        println(io, "Warning: no simulation time limit and no CPU time limit — " *
                    "this run ends when its events run out, which may be never.")
        return NO_LIMIT
    end
    simulation_limit(sim_time = sim_time, wall_clock = options.cpu_time_limit)
end

"""
    engine_spec(options) -> EngineSpec

The engine `--engine` and `--workers` describe.

Throws [`CommandLineError`](@ref) when the process cannot start it. The parallel
engine runs its colorizer on the main thread and each worker as a task that does
not yield, so it needs one Julia thread per worker plus one.

A thread count cannot be asked for here: this program hands its whole command
line to `julia_main`, so Julia's own option reader never sees a `--threads`, and
the count is read from `JULIA_NUM_THREADS` before any of this runs.
"""
function engine_spec(options::Options)
    options.engine === :sequential && return SequentialEngineSpec()
    spec = options.workers === nothing ? ParallelEngineSpec() :
                                         ParallelEngineSpec(options.workers)
    engine_startable(spec) ||
        throw(CommandLineError("the parallel engine needs $(engine_min_threads(spec)) " *
                               "Julia threads and this process has " *
                               "$(Threads.nthreads()) — start it with " *
                               "`JULIA_NUM_THREADS=$(engine_min_threads(spec)) $PROGRAM_NAME …`, " *
                               "or ask for fewer workers"))
    spec
end

"""
    check_engine(options) -> nothing

Refuse an engine this process cannot start, before anything is read or built.
"""
check_engine(options::Options) = (engine_spec(options); nothing)

"""
    engine_text(spec) -> String

What the run says it is running on, and what to make of it. The sequential
engine is the default and says nothing, so the block appears only when there is
something to say.

Two warnings and not one. The first is the engine's, and `omnetpp-julia` prints
it too. The second is this repository's own: the queuing elements interact by
direct call rather than through a connection with a delay, which is outside the
colourer's argument entirely — `package/runner/doc/runner.md` carries the
measurement.
"""
engine_text(::SequentialEngineSpec) = ""
engine_text(spec::ParallelEngineSpec) = string(
    "Engine: parallel, $(spec.n_workers) worker(s) on $(Threads.nthreads()) thread(s).\n",
    "Warning: the parallel engine is not yet deterministic — see\n",
    "         omnetpp-julia's plan/pending/omnetpp-parity.md §5.1.\n",
    "Warning: a queuing element pushes a packet by calling its peer directly, so\n",
    "         that interaction never becomes an edge the colourer can see. This\n",
    "         repository's models are outside what the engine's argument covers.")

end # module RunnerModule
