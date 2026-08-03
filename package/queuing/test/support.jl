# Shared support for the queuing tests: building a small network, running it,
# and reading back what it recorded.

using OmnetppSimulator
using OmnetppSimulator.NetworkModule
using InetQueuing.PacketProtocolModule

"""
    run_network!(network; until = 1.0, recorder = nothing) -> engine

Take a wired network through everything a run does — resolve every module's
peers, check the wiring, declare the statistics, start the modules, run until
`until` seconds, then let each module derive its scalars.
"""
function run_network!(network; until::Real = 1.0, recorder = nothing)
    initialize_network!(network)
    check_packet_connections(network)
    engine = SequentialSimulator(network_module_count(network))
    engine.limit = simulation_limit(sim_time = Float64(until))
    register_network_statistics!(network, recorder)
    start_network!(engine, network)
    run!(engine)
    finalize_network!(network, recorder)
    engine
end

"""
    statistic_samples(recorder, path, name) -> Vector{Tuple{Float64,Float64}}

The `(time, value)` samples a module recorded into one of its time series.
"""
function statistic_samples(recorder::Recorder, path::AbstractString, name::AbstractString)
    full = string(name, ":vector")
    for shadow in recorder.handle_shadows
        shadow.module_path == path && shadow.name == full && return shadow.samples
    end
    error("no statistic $full recorded by $path")
end

"""
    statistic_scalar(recorder, path, name)

The end-of-run scalar a module recorded under its path.
"""
statistic_scalar(recorder::Recorder, path::AbstractString, name::AbstractString) =
    recorder.scalars[Symbol(path, '.', name)]
