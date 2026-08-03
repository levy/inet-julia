"""
    PacketProtocolModule

**How packets move between modules**: the four roles a module can play at a
gate, and the methods each role answers.

A connection joins two modules, and exactly one of them drives it. Where the
upstream module decides when a packet moves, it *pushes* into a passive
consumer; where the downstream module decides, it *pulls* from a passive
provider. That gives four roles, which combine freely: a queue is passive at
both ends (pushed into, pulled from), a server is active at both (it pulls a
packet in and pushes the result out), and a source or a sink is one of each.

Julia has single inheritance and these roles do not nest, so a role is not a
supertype. It is an interface *name* — [`PassivePacketSink`](@ref) and the other
three — that a module claims on a gate and whose methods it implements. Lookup
finds modules by those names; nothing subtypes them.

Alongside the packets there is flow control, running the opposite way: a passive
module tells its active peer when the answer to "can you take another one?" has
changed, and the peer resumes. Those notifications are the reason a full queue
does not need polling and a producer does not need to guess.

Delivery is a direct call. Reaching a consumer over an ideal connection means
calling its [`push_packet!`](@ref) inside the caller's own event; only a
connection with a propagation delay turns into a scheduled event.
[`push_or_schedule!`](@ref) is the one place that decides which, so no element
has to.

The module lives in fragments that share this namespace: one per role —
[`PassivePacketSink.jl`](PassivePacketSink.jl),
[`ActivePacketSource.jl`](ActivePacketSource.jl),
[`PassivePacketSource.jl`](PassivePacketSource.jl),
[`ActivePacketSink.jl`](ActivePacketSink.jl) — and
[`ContractDefaults.jl`](ContractDefaults.jl) for what a module need not say
itself, the delivery helpers, and the wiring check.
"""
module PacketProtocolModule

using OmnetppSimulator: SimTime, ZERO_DELAY, schedule!
using OmnetppSimulator.NetworkModule: Gate, GateInput, GateOutput, Network,
    module_name, module_id, module_gates, gate_name, network_modules, next_gate
using ..PacketModule: Packet
using ..LookupModule: ModuleInterface, ModuleRef, is_resolved,
    InterfaceClaim, ForwardClaim, claims_interface, find_module_interface

export
    # the four roles
    PassivePacketSink, ActivePacketSource, PassivePacketSource, ActivePacketSink,
    # pushing, and its flow control
    can_push_some_packet, can_push_packet, push_packet!,
    handle_can_push_packet_changed!, handle_push_packet_processed!,
    # pulling, and its flow control
    can_pull_some_packet, can_pull_packet, pull_packet!,
    handle_can_pull_packet_changed!, handle_pull_packet_processed!,
    # delivery and wiring
    push_or_schedule!, check_packet_connections

include("PassivePacketSink.jl")
include("ActivePacketSource.jl")
include("PassivePacketSource.jl")
include("ActivePacketSink.jl")
include("ContractDefaults.jl")

end # module
