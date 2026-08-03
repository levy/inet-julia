"""
    PacketSchedulerElement

**The join**: several sources of packets, one output, and a rule for whose turn
it is.

It is the mirror of the classifier and works on the pull side: whoever pulls
from its output gets a packet chosen from among its inputs. The choice is a
Julia function of the module, returning which input to take from — INET's
scheduler classes and their NED parameters become one element with a different
function in it. [`priority_scheduler`](@ref) takes from the first input that has
anything, which is what makes a set of queues a priority queue.

Because the choice is asked afresh for every question — is there anything to
pull, what would it be, hand it over — a scheduler holds nothing itself and
follows its inputs as they fill and empty.
"""
module PacketSchedulerElement

using OmnetppSimulator: NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, GateInput, Network,
    output_gate, gate_vector, module_id
using ..PacketModule: Packet, bits, data_length
using ..LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSource, ActivePacketSink,
    can_pull_some_packet, can_pull_packet, pull_packet!,
    handle_can_pull_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketSchedulerParameters, PacketSchedulerStatistics, PacketSchedulerModule,
       priority_scheduler, scheduler_inputs

"""
    PacketSchedulerParameters(; scheduler)

`scheduler` is `(m) -> Int`: which input the next packet comes from, counting
from one, or `0` when none of them has anything.
"""
struct PacketSchedulerParameters
    scheduler::Any
end

PacketSchedulerParameters(; scheduler) = PacketSchedulerParameters(scheduler)

mutable struct PacketSchedulerStatistics
    recording::ModuleStatistics
    num_packets::Int
    per_input::Vector{Int}
end

PacketSchedulerStatistics(inputs::Int) =
    PacketSchedulerStatistics(ModuleStatistics(), 0, zeros(Int, inputs))

reset_statistics!(statistics::PacketSchedulerStatistics) =
    (statistics.num_packets = 0; fill!(statistics.per_input, 0); statistics)

const STATISTIC_NAMES = (:packetLengths,)

mutable struct PacketSchedulerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Vector{Gate}
    out::Gate
    parameters::PacketSchedulerParameters
    statistics::PacketSchedulerStatistics
    providers::Vector{ModuleRef}
    collector::ModuleRef
end

function PacketSchedulerModule(name::Symbol, inputs::Int,
                               parameters::PacketSchedulerParameters)
    m = PacketSchedulerModule(
        name, 0, Gate[],
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(PassivePacketSource)]),
        parameters, PacketSchedulerStatistics(inputs), ModuleRef[], NO_MODULE_REF)
    m.out.owner = m
    # A scheduler pulls from each input, but only if something pulls from it in
    # turn — it stores nothing, so it is a collector only by proxy.
    m.in = gate_vector(m, :in, GateInput, inputs;
                       annotations = () -> Any[ForwardClaim(ActivePacketSink, :out)])
    m
end

"""
    scheduler_inputs(m) -> Int

How many inputs the scheduler has.
"""
scheduler_inputs(m::PacketSchedulerModule) = length(m.in)

"""
    priority_scheduler(name, inputs) -> PacketSchedulerModule

A scheduler that takes from the first input that has anything, so earlier
inputs are served completely before later ones get a turn. A classifier feeding
a queue per priority, drained by one of these, is a priority queue.
"""
priority_scheduler(name::Symbol, inputs::Int) =
    PacketSchedulerModule(name, inputs, PacketSchedulerParameters(
        scheduler = function (m)
            for index in 1:length(m.providers)
                can_pull_some_packet(m.providers[index]) && return index
            end
            0
        end))

function NetworkModule.initialize_module!(::Network, m::PacketSchedulerModule)
    m.providers = [resolve_interface(gate, PassivePacketSource) for gate in m.in]
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketSchedulerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.reset_module!(m::PacketSchedulerModule) = (reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketSchedulerModule, ::Any)
    recording = m.statistics.recording
    record_statistic!(recording, "packets:count", m.statistics.num_packets)
    for index in 1:length(m.statistics.per_input)
        record_statistic!(recording, "packets[$index]:count", m.statistics.per_input[index])
    end
    nothing
end

PacketProtocolModule.can_pull_some_packet(m::PacketSchedulerModule, ::Gate) =
    m.parameters.scheduler(m) != 0

function PacketProtocolModule.can_pull_packet(m::PacketSchedulerModule, ::Gate)
    index = m.parameters.scheduler(m)
    index == 0 ? nothing : can_pull_packet(m.providers[index])
end

function PacketProtocolModule.pull_packet!(ctx, m::PacketSchedulerModule, ::Gate)
    index = m.parameters.scheduler(m)
    index == 0 &&
        error("pull_packet!: none of $(m.name)'s inputs has a packet — the collector " *
              "pulled without asking whether it could")
    packet = pull_packet!(ctx, m.providers[index])
    statistics = m.statistics
    statistics.num_packets += 1
    statistics.per_input[index] += 1
    emit_statistic!(statistics.recording, ctx, :packetLengths, bits(data_length(packet)))
    packet
end

# Any input filling up may change the answer for the whole scheduler, so the
# news is passed on to whoever pulls from it.
function PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::PacketSchedulerModule,
                                                              ::Gate)
    is_resolved(m.collector) && handle_can_pull_packet_changed!(ctx, m.collector)
    nothing
end

end # module
