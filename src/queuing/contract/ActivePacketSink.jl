# Fragment of `PacketProtocolModule` — the **active sink**: the module that
# drives a pull connection. It decides when a packet moves, and is told when the
# provider's ability to hand one over changes.

"""
    ActivePacketSink <: ModuleInterface

The module that **drives** a pull connection: it decides when a packet moves,
asking its provider first and calling [`pull_packet!`](@ref) itself.

Being active means it can be left waiting, so it is also the module flow control
speaks to. When the provider was empty and now has something, it calls
[`handle_can_pull_packet_changed!`](@ref) and the collector goes back to work.
"""
abstract type ActivePacketSink <: ModuleInterface end

"""
    handle_can_pull_packet_changed!(ctx, m, gate) -> nothing

Tell `m` that the answer to "is there anything to pull?" at `gate` may have
changed — a packet arrived in the queue upstream. A collector that was idle for
want of work starts here.

The notification says only that the answer *may* differ; the collector asks
[`can_pull_some_packet`](@ref) itself before pulling.
"""
function handle_can_pull_packet_changed! end

"""
    handle_pull_packet_processed!(ctx, m, gate, packet, successful) -> nothing

Tell `m` that a packet it pulled has finished being processed, and whether that
succeeded. Only streaming and preemption need this, so the default is to ignore
it.
"""
function handle_pull_packet_processed! end

handle_can_pull_packet_changed!(::Any, m, gate::Gate) =
    _no_method("handle_can_pull_packet_changed!", m, gate, ActivePacketSink)
