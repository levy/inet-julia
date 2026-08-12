# ============================================================================
# T1sCapture — the T1S stack's observation seams
# (omnetpp-julia plan/pending/observable-communication.md, Phase 2).
#
# The T1S layers are wired through closure structs installed centrally by
# `_build_state!` (`MacDownlink`, `MacUpcalls`, `PlcaDownlink`,
# `PhyDownlink`, `PhyUpcalls`) — those slots ARE the declared communication
# seams of this stack, so observing them is a matter of extending the
# simulator's `attach_capture_seams!` with a method that re-wraps the
# in-scope slots at preparation time. No protocol code changes, no signals
# to emit, nothing paid when no capture is attached.
#
# Five observation points per node, named by the INET module-path
# convention the .vec cross-comparison already uses, suffixed with the
# vantage the requirement names (service / protocol / wire):
#
#   <node>.eth[0].mac.service.up      frames the MAC delivers to the app
#                                     (MacUpcalls.frame_received; payload: Packet)
#   <node>.eth[0].mac.protocol.down   frames the MAC hands to PLCA
#                                     (MacDownlink.start_frame_tx; payload: Packet)
#   <node>.eth[0].plca.protocol.down  frames PLCA hands to the PHY
#                                     (PlcaDownlink.start_frame_tx; payload: Packet)
#   <node>.eth[0].phy.wire.down       signals the PHY puts on the wire
#                                     (PhyDownlink.send_signal; payload: WireEvent —
#                                      BEACON/COMMIT carry no packet, DATA does)
#   <node>.eth[0].phy.wire.up         signals whose reception completed at this PHY
#                                     (PhyUpcalls.reception_end; payload: WireEvent)
#
# A boundary hand-off is one moment, so a record's send and deliver times
# coincide (ctx.timestamp). The app→MAC hand-off is a direct method call
# on `app.mac` today — not a wiring slot — so it is not observable without
# becoming a declared seam first; deferred honestly rather than faked (see
# the plan's deferred list).
# ============================================================================

import OmnetppSimulator: attach_capture_seams!
using OmnetppSimulator: CaptureAttachment, attach_link_seams!,
    declare_observation_point!, record_tap!

function attach_capture_seams!(m::AT1sModel, att::CaptureAttachment)
    attach_link_seams!(m, att)          # generic declared-Link seams (none today)
    st = m.state
    st === nothing && return nothing
    for (i, node) in enumerate(st.nodes)
        base = string(_inet_node_path(i, m.n_nodes), ".eth[0]")
        _attach_t1s_mac_seams!(att, node, base)
        _attach_t1s_plca_seams!(att, node, base)
        _attach_t1s_phy_seams!(att, node, base)
    end
    nothing
end

function _attach_t1s_mac_seams!(att, node::T1sNode, base::String)
    mac = node.mac
    # Service vantage, upward: what the MAC delivers to the layer above.
    pt, taps = declare_observation_point!(att, "$base.mac.service.up";
                                          dest_modid = node.module_id)
    if !isempty(taps)
        orig = mac.upcalls
        received = orig.frame_received
        mac.upcalls = MacUpcalls(
            (ctx, m2, pk) -> begin
                record_tap!(taps, pt, ctx, ctx.timestamp, pk)
                received(ctx, m2, pk)
            end,
            orig.frame_sent)
    end
    # Protocol vantage, downward: what the MAC hands to PLCA.
    pt2, taps2 = declare_observation_point!(att, "$base.mac.protocol.down";
                                            dest_modid = node.module_id)
    if !isempty(taps2)
        orig = mac.downlink
        start_frame = orig.start_frame_tx
        mac.downlink = MacDownlink(
            (ctx, pk, esd) -> begin
                record_tap!(taps2, pt2, ctx, ctx.timestamp, pk)
                start_frame(ctx, pk, esd)
            end,
            orig.end_frame_tx, orig.start_signal_tx, orig.end_signal_tx)
    end
    nothing
end

function _attach_t1s_plca_seams!(att, node::T1sNode, base::String)
    plca = node.plca
    # Protocol vantage, downward: the data frames PLCA hands to the PHY.
    pt, taps = declare_observation_point!(att, "$base.plca.protocol.down";
                                          dest_modid = node.module_id)
    if !isempty(taps)
        orig = plca.downlink
        start_frame = orig.start_frame_tx
        plca.downlink = PlcaDownlink(
            orig.start_signal_tx, orig.end_signal_tx,
            (ctx, pk, esd) -> begin
                record_tap!(taps, pt, ctx, ctx.timestamp, pk)
                start_frame(ctx, pk, esd)
            end,
            orig.end_frame_tx)
    end
    nothing
end

function _attach_t1s_phy_seams!(att, node::T1sNode, base::String)
    phy = node.phy
    # The wire, downward: every signal this PHY starts transmitting.
    pt, taps = declare_observation_point!(att, "$base.phy.wire.down";
                                          dest_modid = node.module_id)
    if !isempty(taps)
        orig = phy.downlink
        send = orig.send_signal
        phy.downlink = PhyDownlink(
            (ctx, sig) -> begin
                record_tap!(taps, pt, ctx, ctx.timestamp, sig)
                send(ctx, sig)
            end,
            orig.truncate_signal)
    end
    # The wire, upward: every signal whose reception completed here.
    pt2, taps2 = declare_observation_point!(att, "$base.phy.wire.up";
                                            dest_modid = node.module_id)
    if !isempty(taps2)
        orig = phy.upcalls
        reception_end = orig.reception_end
        phy.upcalls = PhyUpcalls(
            orig.carrier_sense_start, orig.carrier_sense_end,
            orig.collision_start, orig.collision_end,
            orig.reception_start,
            (ctx, p, sig) -> begin
                record_tap!(taps2, pt2, ctx, ctx.timestamp, sig)
                reception_end(ctx, p, sig)
            end)
    end
    nothing
end
