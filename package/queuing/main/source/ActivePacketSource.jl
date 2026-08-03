"""
    ActivePacketSourceElement

**A source that pushes**: it produces a packet every production interval and
pushes it into whatever is connected to its output.

It is the driver of its connection, so it is also the one that can be blocked.
When the interval elapses and the consumer cannot take a packet, the source
does not produce and does not set a new timer: it stops, and waits to be told
that pushing is possible again. Two packets are therefore always at least one
production interval apart, and back pressure delays production rather than
queueing behind it.
"""
module ActivePacketSourceElement

using OmnetppSimulator: SimTime, to_simtime, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, GateOutput, Network,
    output_gate, module_id
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, BitLength, Bytes, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, push_or_schedule!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!
using ..PacketSourceModule: PacketTemplate, create_packet

export ActivePacketSourceParameters, ActivePacketSourceStates,
       ActivePacketSourceStatistics, ActivePacketSourceModule

"""
    ActivePacketSourceParameters(; production_interval, initial_production_offset = -1.0,
                                   packet = PacketTemplate())

How often the source produces, when it starts, and what it produces.

`production_interval` is in seconds, and is normally
[`Volatile`](@ref) so each interval is drawn afresh.
`initial_production_offset` is when the first packet appears; negative — the
default — means at once, as the simulation starts.
"""
struct ActivePacketSourceParameters
    production_interval::Any
    initial_production_offset::Float64
    packet::PacketTemplate
end

ActivePacketSourceParameters(; production_interval,
                             initial_production_offset::Real = -1.0,
                             packet::PacketTemplate = PacketTemplate()) =
    ActivePacketSourceParameters(production_interval, Float64(initial_production_offset), packet)

"""
    ActivePacketSourceStates(seed)

What the source carries from one production to the next: its own generator, the
production timer, and whether the initial offset has been waited out.
"""
mutable struct ActivePacketSourceStates
    rng::MersenneTwister
    seed::Int
    timer::TimerHandle
    offset_scheduled::Bool
end

ActivePacketSourceStates(seed::Int) =
    ActivePacketSourceStates(MersenneTwister(seed), seed, TimerHandle(), false)

reset_states!(states::ActivePacketSourceStates) =
    (states.rng = MersenneTwister(states.seed); states.timer = TimerHandle();
     states.offset_scheduled = false; states)

"""
    ActivePacketSourceStatistics()

How many packets the source produced and how much data they came to.
"""
mutable struct ActivePacketSourceStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int      # bits
end

ActivePacketSourceStatistics() = ActivePacketSourceStatistics(ModuleStatistics(), 0, 0)

reset_statistics!(statistics::ActivePacketSourceStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0; statistics)

const STATISTIC_NAMES = (:packetLengths,)

"""
    ActivePacketSourceModule(name, parameters; seed = 0)

The module: its gate, the consumer it found there, and its parameters, state
and statistics.
"""
mutable struct ActivePacketSourceModule <: AbstractModule
    name::Symbol
    module_id::Int
    out::Gate
    parameters::ActivePacketSourceParameters
    states::ActivePacketSourceStates
    statistics::ActivePacketSourceStatistics
    consumer::ModuleRef
end

function ActivePacketSourceModule(name::Symbol, parameters::ActivePacketSourceParameters;
                                  seed::Int = 0)
    m = ActivePacketSourceModule(
        name, 0,
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, ActivePacketSourceStates(seed), ActivePacketSourceStatistics(),
        NO_MODULE_REF)
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::ActivePacketSourceModule)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::ActivePacketSourceModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(::ActivePacketSourceModule) = true

NetworkModule.start_module!(ctx, m::ActivePacketSourceModule) =
    (_schedule_and_produce!(ctx, m); m)

NetworkModule.reset_module!(m::ActivePacketSourceModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::ActivePacketSourceModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    record_statistic!(m.statistics.recording, "packetLengths:sum", m.statistics.total_length)
    nothing
end

# Told that pushing may be possible again. The source only reacts when it is
# actually stopped: with a timer outstanding the interval has not elapsed yet,
# and producing now would be sooner than the interval allows.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::ActivePacketSourceModule,
                                                              ::Gate)
    is_scheduled(m.states.timer) || _schedule_and_produce!(ctx, m)
    nothing
end

# The one place the source decides what happens next, called at the start, when
# the timer elapses, and when back pressure lifts.
function _schedule_and_produce!(ctx, m::ActivePacketSourceModule)
    parameters, states = m.parameters, m.states
    if !states.offset_scheduled && parameters.initial_production_offset >= 0
        # Waiting out the initial offset: nothing is produced yet.
        _schedule_production!(ctx, m, to_simtime(parameters.initial_production_offset))
        states.offset_scheduled = true
    elseif can_push_some_packet(m.consumer)
        # The next interval is drawn and the timer set before the packet is
        # produced, so an interval measures from one production to the next
        # however long pushing this one takes.
        _schedule_production!(ctx, m, to_simtime(evaluate(parameters.production_interval, states.rng)))
        _produce_packet!(ctx, m)
    end
    # Otherwise the consumer is full: no packet, and no timer, until the
    # consumer says pushing is possible again.
    nothing
end

_schedule_production!(ctx, m::ActivePacketSourceModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.states.timer, c -> _schedule_and_produce!(c, m))

function _produce_packet!(ctx, m::ActivePacketSourceModule)
    packet = create_packet(m.parameters.packet, m.states.rng, ctx.timestamp)
    statistics = m.statistics
    length = bits(data_length(packet))
    statistics.num_packets += 1
    statistics.total_length += length
    emit_statistic!(statistics.recording, ctx, :packetLengths, length)
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

end # module
