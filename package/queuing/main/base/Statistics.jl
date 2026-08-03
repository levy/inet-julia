"""
    StatisticsModule

**What a module records about its run.**

INET declares statistics in NED, as expressions over signals: a source to
listen to, filters to apply, and which of count, sum, histogram or time series
to keep. That little language is not ported. A module here computes what it
reports in ordinary Julia, at the point where it knows the answer, and hands
it to the recorder — a queue emits its length when the length changes, a sink
works out a packet's lifetime from the tag it carries.

What is kept from INET is the naming. Statistics go out under the same names
and the same module paths as INET's, so a run of the ported model and a run of
the original produce result files that compare directly, which is how the port
is checked.

Recording is off unless a run asks for it, and a module that is not recording
pays a single comparison per statistic — [`ModuleStatistics`](@ref) starts with
no recorder, and every emission returns immediately.
"""
module StatisticsModule

using OmnetppSimulator: SimTime, Recorder,
    register_indexed_vector!, emit_indexed_vector!, record_scalar!

export ModuleStatistics, register_statistics!, emit_statistic!, emit_time_statistic!,
       record_statistic!, is_recording

"""
    ModuleStatistics()

A module's recording state: where it records to, and the handle of each time
series it declared. Built empty — a module under test, or a run that keeps no
results, never attaches a recorder and every emission is a no-op.
"""
mutable struct ModuleStatistics
    path::String
    recorder::Any
    vectors::Dict{Symbol,Int}
end

ModuleStatistics() = ModuleStatistics("", nothing, Dict{Symbol,Int}())

"""
    is_recording(statistics) -> Bool

Whether anything is being recorded at all.
"""
is_recording(statistics::ModuleStatistics) = statistics.recorder !== nothing

"""
    register_statistics!(statistics, recorder, path, names) -> statistics

Declare the time series a module records, under its own module path. Each name
is registered as INET spells it in a result file, `name:vector`, so the series
lines up with the same statistic recorded by INET.

With no recorder this only remembers the path, and the module records nothing.
"""
function register_statistics!(statistics::ModuleStatistics, recorder, path::AbstractString, names)
    statistics.path = String(path)
    statistics.recorder = recorder
    recorder === nothing && return statistics
    for name in names
        statistics.vectors[name] =
            register_indexed_vector!(recorder, statistics.path, string(name, ":vector"))
    end
    statistics
end

"""
    emit_statistic!(statistics, ctx, name, value) -> nothing

Add one sample to a time series, at the current simulation time.
"""
function emit_statistic!(statistics::ModuleStatistics, ctx, name::Symbol, value)
    statistics.recorder === nothing && return nothing
    index = get(statistics.vectors, name, 0)
    index == 0 && return nothing
    emit_indexed_vector!(statistics.recorder, index, ctx, Float64(value))
    nothing
end

"""
    emit_time_statistic!(statistics, ctx, name, value::SimTime) -> nothing

Add one sample of a duration, converted to seconds — the unit INET records
durations in, so queueing times and lifetimes compare directly.
"""
function emit_time_statistic!(statistics::ModuleStatistics, ctx, name::Symbol, value::SimTime)
    statistics.recorder === nothing && return nothing
    index = get(statistics.vectors, name, 0)
    index == 0 && return nothing
    emit_indexed_vector!(statistics.recorder, index, ctx, value)
    nothing
end

"""
    record_statistic!(statistics, name, value) -> nothing

Record one end-of-run scalar, under the module's path — `"Net.source.packets:count"`.
Scalars are a module's summary of the whole run, so this belongs in
`finalize_module!`, where the terminal state is known.
"""
function record_statistic!(statistics::ModuleStatistics, name::AbstractString, value)
    statistics.recorder === nothing && return nothing
    record_scalar!(statistics.recorder, Symbol(statistics.path, '.', name), value)
    nothing
end

end # module
