"""
    PacketQueueElement

**The queue**: packets are pushed in at one end and pulled out at the other,
and it holds them in between.

It is the element that is passive on both sides, and that is what makes it the
joint of a chain: whatever pushes into it decides when packets arrive, whatever
pulls decides when they leave, and neither has to keep pace with the other.

With no capacity it holds everything. Given one, what happens when it is full
depends on whether it was told how to drop. Without a dropper it refuses, and
its producer feels that as back pressure — the packet stays upstream. With one,
it always accepts and then drops until it fits again, deciding *after* the
insertion which packet goes, so a newly arrived packet can displace one already
stored. That is what lets a priority queue keep the important packet and throw
away the one it was holding.

A comparator keeps the queue sorted, and then "the front" is whatever the
comparator ranks first rather than whatever arrived first.
"""
module PacketQueueElement

using OmnetppSimulator: SimTime, TIME_UNIT, to_simtime, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network,
    input_gate, output_gate, module_id
using InetPacket.PacketModule: Packet, BitLength, Bits, Bytes, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    handle_can_pull_packet_changed!, handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!

export PacketQueueParameters, PacketQueueStates, PacketQueueStatistics, PacketQueueModule,
       queue_length, queue_bit_length, queue_packet, is_queue_empty,
       drop_at_end, drop_at_begin, drop_tail_queue, drop_head_queue

"""
    drop_at_end(queue) -> Int

Drop the packet at the end of the queue — the one most recently added, which
for an unsorted queue is the one that just arrived. This is drop-tail, INET's
`PacketAtCollectionEndDropper`.
"""
drop_at_end(m) = queue_length(m)

"""
    drop_at_begin(queue) -> Int

Drop the packet at the front of the queue — the one that would have been pulled
next. This is drop-head, INET's `PacketAtCollectionBeginDropper`.
"""
drop_at_begin(::Any) = 1

"""
    PacketQueueParameters(; packet_capacity = nothing, data_capacity = nothing,
                            dropper = nothing, comparator = nothing)

How much the queue holds, what it drops when that is exceeded, and in what
order it keeps packets.

A capacity of `nothing` is no limit. `dropper` chooses which packet goes when
the queue is over capacity, as an index into it — with none, an over-capacity
queue refuses instead. `comparator` is a `(a, b) -> Bool` ranking, and a queue
given one keeps itself sorted.
"""
struct PacketQueueParameters
    packet_capacity::Union{Nothing,Int}
    data_capacity::Union{Nothing,BitLength}
    dropper::Any
    comparator::Any
end

PacketQueueParameters(; packet_capacity::Union{Nothing,Integer} = nothing,
                      data_capacity::Union{Nothing,BitLength} = nothing,
                      dropper = nothing, comparator = nothing) =
    PacketQueueParameters(packet_capacity === nothing ? nothing : Int(packet_capacity),
                          data_capacity, dropper, comparator)

"""
    PacketQueueStates()

The packets held, when each arrived, and the running integral of the queue's
length — which is how the time-average length is known at the end without
sampling it.
"""
mutable struct PacketQueueStates
    packets::Vector{Packet}
    arrival_times::Vector{SimTime}
    total_length::Int              # bits currently held
    length_area::Float64           # ∫ length dt, in packet-seconds
    last_change::SimTime
end

PacketQueueStates() = PacketQueueStates(Packet[], SimTime[], 0, 0.0, SimTime(0))

reset_states!(states::PacketQueueStates) =
    (empty!(states.packets); empty!(states.arrival_times); states.total_length = 0;
     states.length_area = 0.0; states.last_change = SimTime(0); states)

mutable struct PacketQueueStatistics
    recording::ModuleStatistics
    num_pushed::Int
    num_pulled::Int
    num_dropped::Int
    total_queueing_time::SimTime
end

PacketQueueStatistics() = PacketQueueStatistics(ModuleStatistics(), 0, 0, 0, SimTime(0))

reset_statistics!(statistics::PacketQueueStatistics) =
    (statistics.num_pushed = 0; statistics.num_pulled = 0; statistics.num_dropped = 0;
     statistics.total_queueing_time = SimTime(0); statistics)

const STATISTIC_NAMES = (:queueLength, :queueBitLength, :queueingTime)

mutable struct PacketQueueModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketQueueParameters
    states::PacketQueueStates
    statistics::PacketQueueStatistics
    producer::ModuleRef
    collector::ModuleRef
end

function PacketQueueModule(name::Symbol,
                           parameters::PacketQueueParameters = PacketQueueParameters())
    m = PacketQueueModule(
        name, 0,
        # A queue answers a lookup for something to push into only when
        # something downstream will pull: a queue nobody empties is not a sink.
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out;
                                                  forwarded = ActivePacketSink)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(PassivePacketSource)]),
        parameters, PacketQueueStates(), PacketQueueStatistics(),
        NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

"""
    drop_tail_queue(name; packet_capacity = 100) -> PacketQueueModule

A queue that drops the packet that has just arrived when it is full — INET's
`DropTailQueue`, which is this queue with a capacity and a dropper.
"""
drop_tail_queue(name::Symbol; packet_capacity::Integer = 100) =
    PacketQueueModule(name, PacketQueueParameters(packet_capacity = packet_capacity,
                                                  dropper = drop_at_end))

"""
    drop_head_queue(name; packet_capacity = 100) -> PacketQueueModule

A queue that makes room by dropping the packet at the front — INET's
`DropHeadQueue`.
"""
drop_head_queue(name::Symbol; packet_capacity::Integer = 100) =
    PacketQueueModule(name, PacketQueueParameters(packet_capacity = packet_capacity,
                                                  dropper = drop_at_begin))

"""
    queue_length(m) -> Int

How many packets the queue holds.
"""
queue_length(m::PacketQueueModule) = length(m.states.packets)

"""
    queue_bit_length(m) -> Int

How much data the queue holds, in bits.
"""
queue_bit_length(m::PacketQueueModule) = m.states.total_length

"""
    queue_packet(m, index) -> Packet

The packet at `index`, counting from the front.
"""
queue_packet(m::PacketQueueModule, index::Int) = m.states.packets[index]

is_queue_empty(m::PacketQueueModule) = isempty(m.states.packets)

function NetworkModule.initialize_module!(::Network, m::PacketQueueModule)
    # The producer matters only to a queue that refuses; the collector is what
    # empties it, and every queue needs one.
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketQueueModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.reset_module!(m::PacketQueueModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketQueueModule, ::Any)
    statistics, states = m.statistics, m.states
    recording = statistics.recording
    record_statistic!(recording, "packets:count", statistics.num_pushed)
    record_statistic!(recording, "droppedPacketsQueueOverflow:count", statistics.num_dropped)
    # The mean length over the run, from the integral kept as the queue changed
    # rather than from samples — exact, and free.
    duration = Float64(states.last_change) / TIME_UNIT
    duration > 0 && record_statistic!(recording, "queueLength:timeavg",
                                      states.length_area / duration)
    statistics.num_pulled == 0 && return nothing
    record_statistic!(recording, "queueingTime:mean",
                      statistics.total_queueing_time / statistics.num_pulled / TIME_UNIT)
    nothing
end

# ── Being pushed into ──────────────────────────────────────────────────────

# A queue that knows how to drop always has room: it takes the packet and then
# decides what no longer fits, which is what lets an arriving packet displace a
# stored one.
PacketProtocolModule.can_push_some_packet(m::PacketQueueModule, ::Gate) =
    m.parameters.dropper !== nothing || !_is_full(m)

PacketProtocolModule.can_push_packet(m::PacketQueueModule, gate::Gate, ::Packet) =
    PacketProtocolModule.can_push_some_packet(m, gate)

function PacketProtocolModule.push_packet!(ctx, m::PacketQueueModule, ::Gate, packet::Packet)
    parameters, states, statistics = m.parameters, m.states, m.statistics
    _advance_length_integral!(states, ctx.timestamp)
    _insert_packet!(m, packet, ctx.timestamp)
    statistics.num_pushed += 1

    if parameters.dropper !== nothing
        while _is_overloaded(m)
            _drop_packet!(ctx, m, parameters.dropper(m))
        end
    elseif _is_overloaded(m)
        error("push_packet!: $(m.name) is over capacity and has no dropper — " *
              "the producer pushed without asking whether it could")
    end
    _emit_length!(m, ctx)

    # State first, then the notification: the collector may pull straight back
    # into this queue while the call is still on the stack.
    is_resolved(m.collector) && !isempty(states.packets) &&
        handle_can_pull_packet_changed!(ctx, m.collector)
    nothing
end

function _insert_packet!(m::PacketQueueModule, packet::Packet, time::SimTime)
    states, comparator = m.states, m.parameters.comparator
    position = length(states.packets) + 1
    if comparator !== nothing
        # Sorted: the packet goes ahead of the first one it outranks, so equal
        # ranks stay in arrival order.
        position = something(findfirst(stored -> comparator(packet, stored), states.packets),
                             position)
    end
    insert!(states.packets, position, packet)
    insert!(states.arrival_times, position, time)
    states.total_length += bits(data_length(packet))
    nothing
end

function _drop_packet!(ctx, m::PacketQueueModule, index::Int)
    states = m.states
    packet = states.packets[index]
    deleteat!(states.packets, index)
    deleteat!(states.arrival_times, index)
    states.total_length -= bits(data_length(packet))
    m.statistics.num_dropped += 1
    nothing
end

_is_full(m::PacketQueueModule) = _exceeds(m, 0)
_is_overloaded(m::PacketQueueModule) = _exceeds(m, 1)

# Full means "one more would not fit"; overloaded means "what is held already
# does not fit". The same comparison, one packet apart.
function _exceeds(m::PacketQueueModule, slack::Int)
    parameters, states = m.parameters, m.states
    capacity = parameters.packet_capacity
    capacity !== nothing && length(states.packets) >= capacity + slack && return true
    data_capacity = parameters.data_capacity
    data_capacity !== nothing && states.total_length >= bits(data_capacity) + slack && return true
    false
end

# ── Being pulled from ──────────────────────────────────────────────────────

PacketProtocolModule.can_pull_some_packet(m::PacketQueueModule, ::Gate) =
    !isempty(m.states.packets)

PacketProtocolModule.can_pull_packet(m::PacketQueueModule, ::Gate) =
    isempty(m.states.packets) ? nothing : m.states.packets[1]

function PacketProtocolModule.pull_packet!(ctx, m::PacketQueueModule, ::Gate)
    states, statistics = m.states, m.statistics
    isempty(states.packets) &&
        error("pull_packet!: $(m.name) is empty — the collector pulled without " *
              "asking whether it could")
    _advance_length_integral!(states, ctx.timestamp)
    was_full = _is_full(m)
    packet = popfirst!(states.packets)
    arrived = popfirst!(states.arrival_times)
    states.total_length -= bits(data_length(packet))
    statistics.num_pulled += 1

    queueing_time = ctx.timestamp - arrived
    statistics.total_queueing_time += queueing_time
    emit_time_statistic!(statistics.recording, ctx, :queueingTime, queueing_time)
    _emit_length!(m, ctx)

    # A queue that was refusing has room again, and the producer that stopped
    # is waiting to be told. INET leaves this out, so a full queue with no
    # dropper never restarts its producer.
    was_full && is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    packet
end

# ── Statistics ─────────────────────────────────────────────────────────────

# The length integral is advanced before every change, so it always covers the
# stretch of time the queue has just spent at its current length.
function _advance_length_integral!(states::PacketQueueStates, now::SimTime)
    elapsed = now - states.last_change
    elapsed > 0 && (states.length_area += length(states.packets) * (Float64(elapsed) / TIME_UNIT))
    states.last_change = now
    nothing
end

function _emit_length!(m::PacketQueueModule, ctx)
    recording = m.statistics.recording
    emit_statistic!(recording, ctx, :queueLength, length(m.states.packets))
    emit_statistic!(recording, ctx, :queueBitLength, m.states.total_length)
    nothing
end

end # module
