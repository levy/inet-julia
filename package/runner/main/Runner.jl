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

using OmnetppSimulator: SimulationType, ParameterAssignment, configure_simulation,
    expand_simulation, prepare_simulation_execution, SequentialEngineSpec,
    run_simulation!, finish_simulation!, simulation_stop_reason, stop_reason_text,
    attach_sink!, OmnetppTextSink
using InetQueuing: QueuingModel

using ..CommandLineModule: Options, PROGRAM_NAME, version_text

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

    println(io, version_text())
    println(io, "Preparing configuration $(options.config), run #$(options.run - 1).")

    execution = prepare_simulation_execution(run; engine = SequentialEngineSpec())
    mkpath(options.result_dir)
    scalar_path = joinpath(options.result_dir, "$(options.config)-#$(options.run - 1).sca")
    attach_sink!(execution.recorder,
                 OmnetppTextSink(; sca_path = scalar_path, run_name = options.config))

    println(io, "Running the simulation.")
    run_simulation!(execution)
    result = finish_simulation!(execution)

    println(io, "Finished: $(result.time) s, $(result.event_count) events, " *
                "$(stop_reason_text(simulation_stop_reason(execution))).")
    println(io, "Results: $scalar_path")
    Cint(0)
end

end # module RunnerModule
