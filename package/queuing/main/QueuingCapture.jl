# ============================================================================
# QueuingCapture — the queuing elements' observation seams
# (omnetpp-julia plan/pending/observable-communication.md, Phase 3).
#
# Queuing modules communicate through resolved `ModuleRef`s: a producer
# holds `consumer::ModuleRef` and pushes through it, a puller holds
# `provider::ModuleRef` and pulls through it, and flow-control
# notifications travel back through reference fields of their own. Those
# fields ARE this library's declared communication seams — the analog of
# the T1S stack's downlink/upcalls slots — so observing them is the same
# move: at attach time, each in-scope reference is replaced by one whose
# target is a `TappedPacketPeer`, a forwarding proxy that records the
# packets crossing `push_packet!` / `pull_packet!` and forwards everything
# else untouched. Flow-control-only references (a queue's back-reference
# to its producer) become observation points that simply never carry a
# record — the seam exists, nothing crossed it.
#
# Zero cost when off (no capture → no proxy, the resolved references are
# the originals), cost proportional to scope, determinism-neutral — the
# same three guarantees as every other seam kind, inherited from
# record_tap!.
# ============================================================================

import .PacketProtocolModule: can_push_some_packet, can_push_packet, push_packet!,
    handle_can_push_packet_changed!, handle_push_packet_processed!,
    can_pull_some_packet, can_pull_packet, pull_packet!,
    handle_can_pull_packet_changed!, handle_pull_packet_processed!
using InetCommon.LookupModule: ModuleRef, is_resolved
using InetPacket.PacketModule: Packet
using OmnetppSimulator: CaptureAttachment, CaptureTaps, ObservationPoint,
    attach_link_seams!, declare_observation_point!, record_tap!, SimTime
import OmnetppSimulator: attach_capture_seams!
import OmnetppSimulator.NetworkModule: module_id
using OmnetppSimulator.NetworkModule: network_modules, module_name, Gate

"""
    TappedPacketPeer

The forwarding proxy standing in for one observed `ModuleRef` target:
records what crosses the packet-carrying contract calls, forwards every
contract call to the real module. `delay` is the reference's connection
delay, so a scheduled push records the send moment it left the producer.
"""
struct TappedPacketPeer
    target::Any
    pt::ObservationPoint
    taps::CaptureTaps
    delay::SimTime
end

# The two packet-carrying calls — the taps.
function push_packet!(ctx, p::TappedPacketPeer, gate::Gate, packet::Packet)
    record_tap!(p.taps, p.pt, ctx.timestamp - p.delay, ctx.timestamp, packet)
    push_packet!(ctx, p.target, gate, packet)
end
function pull_packet!(ctx, p::TappedPacketPeer, gate::Gate)
    packet = pull_packet!(ctx, p.target, gate)
    record_tap!(p.taps, p.pt, ctx.timestamp, ctx.timestamp, packet)
    packet
end

# Everything else forwards untouched.
can_push_some_packet(p::TappedPacketPeer, gate::Gate) = can_push_some_packet(p.target, gate)
can_push_packet(p::TappedPacketPeer, gate::Gate, packet::Packet) = can_push_packet(p.target, gate, packet)
handle_can_push_packet_changed!(ctx, p::TappedPacketPeer, gate::Gate) =
    handle_can_push_packet_changed!(ctx, p.target, gate)
handle_push_packet_processed!(ctx, p::TappedPacketPeer, gate::Gate, packet::Packet, successful) =
    handle_push_packet_processed!(ctx, p.target, gate, packet, successful)
can_pull_some_packet(p::TappedPacketPeer, gate::Gate) = can_pull_some_packet(p.target, gate)
can_pull_packet(p::TappedPacketPeer, gate::Gate) = can_pull_packet(p.target, gate)
handle_can_pull_packet_changed!(ctx, p::TappedPacketPeer, gate::Gate) =
    handle_can_pull_packet_changed!(ctx, p.target, gate)
handle_pull_packet_processed!(ctx, p::TappedPacketPeer, gate::Gate, packet::Packet, successful) =
    handle_pull_packet_processed!(ctx, p.target, gate, packet, successful)
module_id(p::TappedPacketPeer) = module_id(p.target)

"""
    attach_packet_peer_seams!(att, network; prefix = String(network.name))

Declare an observation point for every resolved `ModuleRef` field of every
module in `network` — named `<prefix>.<module>.<field>`, in module order,
fields in declaration order — and wrap the in-scope ones. Callable from
any model's `attach_capture_seams!` whose network is wired through the
packet-protocol contract.
"""
function attach_packet_peer_seams!(att::CaptureAttachment, network;
                                   prefix::AbstractString = String(network.name))
    for mod in network_modules(network)
        T = typeof(mod)
        for f in fieldnames(T)
            ref = getfield(mod, f)
            ref isa ModuleRef && is_resolved(ref) && ref.gate isa Gate || continue
            path = string(prefix, ".", String(module_name(mod)), ".", String(f))
            pt, taps = declare_observation_point!(att, path;
                                                  dest_modid = module_id(ref.target),
                                                  delay = ref.delay)
            isempty(taps) && continue
            proxy = TappedPacketPeer(ref.target, pt, taps, ref.delay)
            setfield!(mod, f, ModuleRef(proxy, ref.gate, ref.delay))
        end
    end
    nothing
end

function attach_capture_seams!(m::AQueuingModel, att::CaptureAttachment)
    attach_link_seams!(m, att)          # generic declared-Link seams (none today)
    attach_packet_peer_seams!(att, m.network)
    nothing
end
