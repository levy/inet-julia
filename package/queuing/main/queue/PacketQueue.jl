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

using OmnetppSimulator: SimTime, seconds, to_simtime, NetworkModule
using OmnetppSimulator.NetworkModule: SimulationModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using InetPacket.PacketModule: Packet, BitLength, Bits, Bytes, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    handle_can_pull_packet_changed!, handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!

export PacketQueueModule,
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
    PacketQueueModule(name; packet_capacity = nothing, …)

The module, declared by the kind of each of its fields.

A capacity of `nothing` is no limit. `dropper` chooses which packet goes when
the queue is over capacity, as an index into it — with none, an over-capacity
queue refuses instead. `comparator` is a `(a, b) -> Bool` ranking, and a queue
given one keeps itself sorted.

`length_area` is the running integral of the queue's length, which is how the
time-average length is known at the end without sampling it.
"""
@simulation_module struct PacketQueueModule
    @parameters begin
        packet_capacity::Union{Nothing,Int} = nothing
        data_capacity::Union{Nothing,BitLength} = nothing
        dropper::Any = nothing
        comparator::Any = nothing
    end
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @variables begin
        packets::Vector{Packet} = Packet[]
        arrival_times::Vector{SimTime} = SimTime[]
        total_length::Int = 0                          # bits currently held
        length_area::Float64 = 0.0                     # ∫ length dt, in packet-seconds
        last_change::SimTime = SimTime(0)
        producer::ModuleRef = NO_MODULE_REF
        collector::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_pushed::Int = 0
        num_pulled::Int = 0
        num_dropped::Int = 0
        total_queueing_time::SimTime = SimTime(0)
    end
end

# The claims a lookup reads off the gates. They must be there before any lookup
# walks the wiring, so they belong to construction rather than to
# initialization. A queue answers a lookup for something to push into only when
# something downstream will pull: a queue nobody empties is not a sink.
function NetworkModule.decorate_module!(m::PacketQueueModule)
    push!(m.in.annotations, ForwardClaim(PassivePacketSink, :out;
                                         forwarded = ActivePacketSink))
    push!(m.out.annotations, InterfaceClaim(PassivePacketSource))
    m
end

const STATISTIC_NAMES = (:queueLength, :queueBitLength, :queueingTime)

"""
    drop_tail_queue(name; packet_capacity = 100) -> PacketQueueModule

A queue that drops the packet that has just arrived when it is full — INET's
`DropTailQueue`, which is this queue with a capacity and a dropper.
"""
drop_tail_queue(name::Symbol; packet_capacity::Integer = 100) =
    PacketQueueModule(name; packet_capacity = packet_capacity, dropper = drop_at_end)

"""
    drop_head_queue(name; packet_capacity = 100) -> PacketQueueModule

A queue that makes room by dropping the packet at the front — INET's
`DropHeadQueue`.
"""
drop_head_queue(name::Symbol; packet_capacity::Integer = 100) =
    PacketQueueModule(name; packet_capacity = packet_capacity, dropper = drop_at_begin)

"""
    queue_length(m) -> Int

How many packets the queue holds.
"""
queue_length(m::PacketQueueModule) = length(m.packets)

"""
    queue_bit_length(m) -> Int

How much data the queue holds, in bits.
"""
queue_bit_length(m::PacketQueueModule) = m.total_length

"""
    queue_packet(m, index) -> Packet

The packet at `index`, counting from the front.
"""
queue_packet(m::PacketQueueModule, index::Int) = m.packets[index]

is_queue_empty(m::PacketQueueModule) = isempty(m.packets)

function NetworkModule.initialize_module!(::Network, m::PacketQueueModule)
    # The producer matters only to a queue that refuses; the collector is what
    # empties it, and every queue needs one.
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketQueueModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

# What a queue is doing now: how much it is holding.
NetworkModule.module_status(m::PacketQueueModule) =
    string(queue_length(m), " waiting")

NetworkModule.module_icon(::PacketQueueModule) = "block/queue"

function NetworkModule.finish_module!(m::PacketQueueModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_pushed)
    record_statistic!(m.recording, "droppedPacketsQueueOverflow:count", m.num_dropped)
    # The mean length over the run, from the integral kept as the queue changed
    # rather than from samples — exact, and free.
    duration = seconds(m.last_change)
    duration > 0 && record_statistic!(m.recording, "queueLength:timeavg",
                                      m.length_area / duration)
    m.num_pulled == 0 && return nothing
    record_statistic!(m.recording, "queueingTime:mean",
                      seconds(m.total_queueing_time / m.num_pulled))
    nothing
end

# ── Being pushed into ──────────────────────────────────────────────────────

# A queue that knows how to drop always has room: it takes the packet and then
# decides what no longer fits, which is what lets an arriving packet displace a
# stored one.
PacketProtocolModule.can_push_some_packet(m::PacketQueueModule, ::Gate) =
    m.dropper !== nothing || !_is_full(m)

PacketProtocolModule.can_push_packet(m::PacketQueueModule, gate::Gate, ::Packet) =
    PacketProtocolModule.can_push_some_packet(m, gate)

function PacketProtocolModule.push_packet!(ctx, m::PacketQueueModule, ::Gate, packet::Packet)
    _advance_length_integral!(m, ctx.timestamp)
    _insert_packet!(m, packet, ctx.timestamp)
    m.num_pushed += 1

    if m.dropper !== nothing
        while _is_overloaded(m)
            _drop_packet!(ctx, m, m.dropper(m))
        end
    elseif _is_overloaded(m)
        error("push_packet!: $(m.name) is over capacity and has no dropper — " *
              "the producer pushed without asking whether it could")
    end
    _emit_length!(m, ctx)

    # State first, then the notification: the collector may pull straight back
    # into this queue while the call is still on the stack.
    is_resolved(m.collector) && !isempty(m.packets) &&
        handle_can_pull_packet_changed!(ctx, m.collector)
    nothing
end

function _insert_packet!(m::PacketQueueModule, packet::Packet, time::SimTime)
    position = length(m.packets) + 1
    if m.comparator !== nothing
        # Sorted: the packet goes ahead of the first one it outranks, so equal
        # ranks stay in arrival order.
        position = something(findfirst(stored -> m.comparator(packet, stored), m.packets),
                             position)
    end
    insert!(m.packets, position, packet)
    insert!(m.arrival_times, position, time)
    m.total_length += bits(data_length(packet))
    nothing
end

function _drop_packet!(ctx, m::PacketQueueModule, index::Int)
    packet = m.packets[index]
    deleteat!(m.packets, index)
    deleteat!(m.arrival_times, index)
    m.total_length -= bits(data_length(packet))
    m.num_dropped += 1
    nothing
end

_is_full(m::PacketQueueModule) = _exceeds(m, 0)
_is_overloaded(m::PacketQueueModule) = _exceeds(m, 1)

# Full means "one more would not fit"; overloaded means "what is held already
# does not fit". The same comparison, one packet apart.
function _exceeds(m::PacketQueueModule, slack::Int)
    capacity = m.packet_capacity
    capacity !== nothing && length(m.packets) >= capacity + slack && return true
    data_capacity = m.data_capacity
    data_capacity !== nothing && m.total_length >= bits(data_capacity) + slack && return true
    false
end

# ── Being pulled from ──────────────────────────────────────────────────────

PacketProtocolModule.can_pull_some_packet(m::PacketQueueModule, ::Gate) =
    !isempty(m.packets)

PacketProtocolModule.can_pull_packet(m::PacketQueueModule, ::Gate) =
    isempty(m.packets) ? nothing : m.packets[1]

function PacketProtocolModule.pull_packet!(ctx, m::PacketQueueModule, ::Gate)
    isempty(m.packets) &&
        error("pull_packet!: $(m.name) is empty — the collector pulled without " *
              "asking whether it could")
    _advance_length_integral!(m, ctx.timestamp)
    was_full = _is_full(m)
    packet = popfirst!(m.packets)
    arrived = popfirst!(m.arrival_times)
    m.total_length -= bits(data_length(packet))
    m.num_pulled += 1

    queueing_time = ctx.timestamp - arrived
    m.total_queueing_time += queueing_time
    emit_time_statistic!(m.recording, ctx, :queueingTime, queueing_time)
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
function _advance_length_integral!(m::PacketQueueModule, now::SimTime)
    elapsed = now - m.last_change
    elapsed > zero(elapsed) && (m.length_area += length(m.packets) * seconds(elapsed))
    m.last_change = now
    nothing
end

function _emit_length!(m::PacketQueueModule, ctx)
    emit_statistic!(m.recording, ctx, :queueLength, length(m.packets))
    emit_statistic!(m.recording, ctx, :queueBitLength, m.total_length)
    nothing
end

end # module
