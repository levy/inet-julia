# Fragment of `PacketProtocolModule` — the **active source**: the module that
# drives a push connection. It decides when a packet moves, and is told when the
# sink's willingness to take one changes.

"""
    ActivePacketSource <: ModuleInterface

The module that **drives** a push connection: it decides when a packet moves,
asking its sink first and calling [`push_packet!`](@ref) itself.

Being active means it can be blocked, so it is also the module flow control
speaks to. When the sink could not take a packet and now can, the sink calls
[`handle_can_push_packet_changed!`](@ref) and the source picks up where it
stopped — which is why nothing here polls.
"""
abstract type ActivePacketSource <: ModuleInterface end

"""
    handle_can_push_packet_changed!(ctx, m, gate) -> nothing

Tell `m` that the answer to "can I push?" at `gate` may have changed — the queue
downstream has room again, the gate downstream has opened. A source that stopped
because it was blocked tries again here.

The notification says only that the answer *may* differ; the source asks
[`can_push_packet`](@ref) itself before pushing.
"""
function handle_can_push_packet_changed! end

"""
    handle_push_packet_processed!(ctx, m, gate, packet, successful) -> nothing

Tell `m` that a packet it pushed has finished being processed downstream, and
whether that succeeded. Only streaming and preemption need this — for a whole
packet, [`push_packet!`](@ref) returning is the completion — so the default is
to ignore it.
"""
function handle_push_packet_processed! end

handle_can_push_packet_changed!(::Any, m, gate::Gate) =
    _no_method("handle_can_push_packet_changed!", m, gate, ActivePacketSource)
