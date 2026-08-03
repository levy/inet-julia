# Fragment of `PacketProtocolModule` — the **passive sink**: a module packets
# are pushed into. Its active peer decides when; it only says whether it can
# take one, and takes it.

"""
    PassivePacketSink <: ModuleInterface

A module packets are **pushed into**. The peer upstream drives: it asks
[`can_push_packet`](@ref) and then calls [`push_packet!`](@ref).

A sink that has to refuse — a full queue — says so through
[`can_push_some_packet`](@ref), and tells its producer when that changes with
[`handle_can_push_packet_changed!`](@ref). Refusing is not the same as dropping:
a refused packet is still upstream's, an accepted one is the sink's.
"""
abstract type PassivePacketSink <: ModuleInterface end

"""
    can_push_some_packet(m, gate) -> Bool

Whether `m` could accept *any* packet at `gate` right now. This is the question
a producer asks before it has a packet to offer, and the one whose answer
[`handle_can_push_packet_changed!`](@ref) reports a change of.
"""
function can_push_some_packet end

"""
    can_push_packet(m, gate, packet) -> Bool

Whether `m` can accept *this* packet at `gate` — the question that a length
limit or a filter answers differently from
[`can_push_some_packet`](@ref).
"""
function can_push_packet end

"""
    push_packet!(ctx, m, gate, packet) -> nothing

Hand `packet` to `m` at `gate`. The packet becomes the sink's: the caller must
not keep or change it afterwards, and duplicating means [`dup`](@ref) first.

Only call this when [`can_push_packet`](@ref) says yes — a sink is entitled to
treat a push it cannot take as an error rather than dropping it silently.
"""
function push_packet! end

_no_method(what::AbstractString, m, gate::Gate, interface) = error(
    "$what: $(module_name(m)) claims $interface at $(gate_name(gate)) but does not " *
    "implement $what — every module claiming that interface has to")

can_push_some_packet(m, gate::Gate) = _no_method("can_push_some_packet", m, gate, PassivePacketSink)
can_push_packet(m, gate::Gate, ::Packet) = _no_method("can_push_packet", m, gate, PassivePacketSink)
push_packet!(::Any, m, gate::Gate, ::Packet) = _no_method("push_packet!", m, gate, PassivePacketSink)
