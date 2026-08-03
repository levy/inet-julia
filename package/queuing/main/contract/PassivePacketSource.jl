# Fragment of `PacketProtocolModule` — the **passive source**: a module packets
# are pulled out of. Its active peer decides when; it only says whether it has
# one, and hands it over.

"""
    PassivePacketSource <: ModuleInterface

A module packets are **pulled out of**. The peer downstream drives: it asks
[`can_pull_packet`](@ref) and then calls [`pull_packet!`](@ref).

An empty provider says so through [`can_pull_some_packet`](@ref), and tells its
collector when that changes with [`handle_can_pull_packet_changed!`](@ref) —
which is how a queue starts a server that had nothing to do.
"""
abstract type PassivePacketSource <: ModuleInterface end

"""
    can_pull_some_packet(m, gate) -> Bool

Whether `m` has *any* packet to hand out at `gate` right now.
"""
function can_pull_some_packet end

"""
    can_pull_packet(m, gate) -> Packet or nothing

The packet [`pull_packet!`](@ref) would hand over, without handing it over —
so a collector can decide by looking at it (does the next stage have room for
one this long?) before committing. `nothing` when there is none.
"""
function can_pull_packet end

"""
    pull_packet!(ctx, m, gate) -> Packet

Take a packet from `m` at `gate`. The packet becomes the caller's, and leaves
the provider.

Only call this when [`can_pull_some_packet`](@ref) says yes — a provider is
entitled to treat a pull it cannot satisfy as an error.
"""
function pull_packet! end

can_pull_some_packet(m, gate::Gate) = _no_method("can_pull_some_packet", m, gate, PassivePacketSource)
can_pull_packet(m, gate::Gate) = _no_method("can_pull_packet", m, gate, PassivePacketSource)
pull_packet!(::Any, m, gate::Gate) = _no_method("pull_packet!", m, gate, PassivePacketSource)
