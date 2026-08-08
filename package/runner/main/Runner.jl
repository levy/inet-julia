# ============================================================================
# The runner — one command line, one run, two result files.
#
# It selects what to run, drives the five lifecycle verbs, and reports what
# happened. The selection is the only part that is temporary: until
# `OmnetppDescription` can read a NED network, a configuration name picks a
# model out of a table (plan/pending/native-simulation-binary.md §4.7, phase 5
# deletes the table).
# ============================================================================

"""
    RunnerModule

Runs the simulation one [`Options`](@ref) describes.
"""
module RunnerModule

using Dates: now

using OmnetppSimulator: SimulationType, ParameterAssignment, configure_simulation,
    expand_simulation, prepare_simulation_execution, SequentialEngineSpec,
    run_simulation!, finish_simulation!, simulation_stop_reason, stop_reason_text,
    simulation_model, attach_sink!, OmnetppTextSink
using InetQueuing: QueuingModel

using ..CommandLineModule: Options, PROGRAM_NAME, version_text
using ..ResultFilesModule: scalar_file_path, vector_file_path, result_run_name,
    result_run_attributes

export run_options, RunFailure

"""
    RunFailure(message)

A command line that reads correctly but describes a run that cannot be made.
The entry point prints the message on stderr and exits 2.
"""
struct RunFailure <: Exception
    message::String
end

Base.showerror(io::IO, e::RunFailure) = print(io, e.message)

# The stand-in for a NED network. Phase 5 of the plan replaces this table with
# `build_network`, and nothing else in this file changes.
const BUILTIN_MODELS = Dict{String,Any}("Queuing" => QueuingModel)

function _model_of(config::AbstractString)
    haskey(BUILTIN_MODELS, config) && return BUILTIN_MODELS[config]
    known = join(sort!(collect(keys(BUILTIN_MODELS))), ", ")
    throw(RunFailure("no configuration named '$config' — this build knows: $known"))
end

# The run the command line asked for, out of the runs the configuration fans
# out into. Both numbers are reported the way the user wrote them, counted
# from 0.
function _selected_run(runs, options::Options)
    options.run <= length(runs) && return runs[options.run]
    throw(RunFailure("run #$(options.run - 1) does not exist — " *
                     "configuration '$(options.config)' has $(length(runs)) run(s), " *
                     "numbered 0 to $(length(runs) - 1)"))
end

# The network a model built. It names the `network` run attribute, which is
# what tells two result files of one configuration apart when the topology
# changed under them. Phase 5 takes it from the INI file's `network =` instead,
# where every model has one whether or not it carries a Network object.
_network_name(model) =
    hasproperty(model, :network) && getproperty(model, :network) !== nothing ?
        String(getproperty(model, :network).name) : ""

"""
    run_options(options; io = stdout) -> Cint

Run what `options` describes, and answer the exit code. Throws
[`RunFailure`](@ref) when the description cannot be made into a run.
"""
function run_options(options::Options; io::IO = stdout)
    model_type = _model_of(options.config)
    runs = expand_simulation(configure_simulation(
        SimulationType(model_type), ParameterAssignment(Dict{Symbol,Any}())))
    run = _selected_run(runs, options)
    run_number = options.run - 1        # reported the way the user wrote it

    println(io, version_text())
    println(io, "Preparing configuration $(options.config), run #$run_number.")

    execution = prepare_simulation_execution(run; engine = SequentialEngineSpec())

    # The moment and the process id go into the run name, so two runs of one
    # configuration are told apart by their header and not only by their path.
    moment = now()
    process_id = getpid()
    mkpath(options.result_dir)
    scalar_path = scalar_file_path(options.result_dir, options.config, run_number)
    vector_path = vector_file_path(options.result_dir, options.config, run_number)
    # One line is still missing here: `split_module_path = true`. A recorder
    # keeps scalars in one flat namespace, so `Queuing.queue.packets:count`
    # lands whole in the name column and the module column stays empty, where
    # OMNeT++ writes `scalar Queuing.queue packets:count`. The option exists on
    # omnetpp-julia's `binary` branch ("A dotted scalar name fills both columns
    # of a scalar line") and is added the moment that lands.
    attach_sink!(execution.recorder,
        OmnetppTextSink(vector_path;
            sca_path = scalar_path,
            run_name = result_run_name(options.config, run_number, moment, process_id),
            run_attributes = result_run_attributes(
                config = options.config, run_number = run_number,
                network = _network_name(simulation_model(execution)),
                moment = moment, process_id = process_id,
                ini_file = first(options.ini_files))))

    println(io, "Running the simulation.")
    run_simulation!(execution)
    result = finish_simulation!(execution)

    println(io, "Finished: $(result.time) s, $(result.event_count) events, " *
                "$(stop_reason_text(simulation_stop_reason(execution))).")
    println(io, "Results: $scalar_path")
    println(io, "         $vector_path")
    Cint(0)
end

end # module RunnerModule
