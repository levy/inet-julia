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

using OmnetppSimulator: SimTime, to_simtime, ZERO_DELAY, schedule_event!, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: SimulationModule, Gate, GateOutput, Network,
    output_gate, module_id, @simulation_module, decorate_module!
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, BitLength, Bytes, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, push_or_schedule!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!
using ..PacketSourceModule: PacketTemplate, create_packet

export ActivePacketSourceModule

"""
    ActivePacketSourceModule(name; production_interval, …)

The module, declared by the kind of each of its fields.

`production_interval` is in seconds and has no default, because a source with
no interval has nothing to say; it is normally [`Volatile`](@ref) so that each
interval is drawn afresh. `initial_production_offset` is when the first packet
appears, and negative — the default — means at once.
"""
@simulation_module struct ActivePacketSourceModule
    @parameters begin
        production_interval::Any                       # no default: it must be given
        initial_production_offset::Float64 = -1.0
        packet::PacketTemplate = PacketTemplate()
        seed::Int = 0
    end
    @gates begin
        out::OutputGate
    end
    @stream rng::MersenneTwister = MersenneTwister(seed)
    @variables begin
        timer::TimerHandle = TimerHandle()
        offset_scheduled::Bool = false
        consumer::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        total_length::Int = 0                          # bits
    end
end

# The claim a lookup reads off the gate. It must be there before any lookup
# walks the wiring, so it belongs to construction rather than to initialization.
NetworkModule.decorate_module!(m::ActivePacketSourceModule) =
    (push!(m.out.annotations, InterfaceClaim(ActivePacketSource)); m)

const STATISTIC_NAMES = (:packetLengths,)

function NetworkModule.initialize_module!(::Network, m::ActivePacketSourceModule)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::ActivePacketSourceModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.start_module!(root, m::ActivePacketSourceModule) =
    (schedule_event!(root, ZERO_DELAY, ctx -> _schedule_and_produce!(ctx, m)); m)

NetworkModule.module_status(m::ActivePacketSourceModule) =
    string(m.num_packets, " sent")

NetworkModule.module_icon(::ActivePacketSourceModule) = "block/source"

function NetworkModule.finish_module!(m::ActivePacketSourceModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    nothing
end

# Told that pushing may be possible again. The source only reacts when it is
# actually stopped: with a timer outstanding the interval has not elapsed yet,
# and producing now would be sooner than the interval allows.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::ActivePacketSourceModule,
                                                              ::Gate)
    is_scheduled(m.timer) || _schedule_and_produce!(ctx, m)
    nothing
end

# The one place the source decides what happens next, called at the start, when
# the timer elapses, and when back pressure lifts.
function _schedule_and_produce!(ctx, m::ActivePacketSourceModule)
    if !m.offset_scheduled && m.initial_production_offset >= 0
        # Waiting out the initial offset: nothing is produced yet.
        _schedule_production!(ctx, m, to_simtime(m.initial_production_offset))
        m.offset_scheduled = true
    elseif can_push_some_packet(m.consumer)
        # The next interval is drawn and the timer set before the packet is
        # produced, so an interval measures from one production to the next
        # however long pushing this one takes.
        _schedule_production!(ctx, m, to_simtime(evaluate(m.production_interval, m.rng)))
        _produce_packet!(ctx, m)
    end
    # Otherwise the consumer is full: no packet, and no timer, until the
    # consumer says pushing is possible again.
    nothing
end

_schedule_production!(ctx, m::ActivePacketSourceModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.timer, c -> _schedule_and_produce!(c, m))

function _produce_packet!(ctx, m::ActivePacketSourceModule)
    packet = create_packet(m.packet, m.rng, ctx.timestamp)
    length = bits(data_length(packet))
    m.num_packets += 1
    m.total_length += length
    emit_statistic!(m.recording, ctx, :packetLengths, length)
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

end # module
