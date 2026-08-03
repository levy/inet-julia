# ============================================================================
# Phase 5 conformance — PLCA data FSM, transmit path only.
#
# Only DS_IDLE / DS_WAIT_IDLE / DS_HOLD / DS_TRANSMIT / DS_RECEIVE exercised.
# The recovery path (DS_COLLIDE / DS_DELAY_PENDING / DS_PENDING / DS_WAIT_MAC)
# lands in Phase 7 once MAC (Phase 6) closes the collision loop.
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

_build_sim(n::Int) = SequentialSimulator(n)

# Recording downlink that ALSO simulates PHY's synchronous CRS callbacks —
# same trick as phase 4, so PLCA sees CRS toggle correctly without a real PHY.
function _looped_recording_downlink(plca_ref::Ref{PlcaState}, sigs::Vector, frames::Vector)
    return PlcaDownlink(
        function (ctx, kind)
            push!(sigs, (:start_signal, kind, ctx.timestamp))
            plca_on_carrier_sense_start!(ctx, plca_ref[])
        end,
        function (ctx)
            push!(sigs, (:end_signal, ctx.timestamp))
            plca_on_carrier_sense_end!(ctx, plca_ref[])
        end,
        function (ctx, pkt, esd)
            push!(frames, (:start_frame, pkt, esd, ctx.timestamp))
            plca_on_carrier_sense_start!(ctx, plca_ref[])
        end,
        function (ctx)
            push!(frames, (:end_frame, ctx.timestamp))
            plca_on_carrier_sense_end!(ctx, plca_ref[])
        end,
    )
end

# --- Coordinator with a packet ready: HOLD → COMMIT → TRANSMIT ---------------

@testset "coord holds packet in DS_HOLD, then transmits at own TO" begin
    sim = _build_sim(2)
    sigs = Any[]
    frames = Any[]
    plca_ref = Ref{PlcaState}()
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0);
                     downlink = _looped_recording_downlink(plca_ref, sigs, frames),
                     upcalls = default_plca_upcalls())
    plca_ref[] = plca

    # 46-byte payload → 64-byte frame after pad+FCS. Wire duration:
    # data_bits(512) + phy_hdr(64) + esd(8) = 584 bits @ 10 Mb = 58.4 µs.
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    # Hand PLCA the packet at t=0.5µs — before it reaches WAIT_TO(cur_id=0).
    schedule_root!(sim, to_simtime(0.5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    run!(sim)

    # A DATA frame should have been sent on the wire (via start_frame_tx).
    starts = filter(f -> f[1] === :start_frame, frames)
    @test !isempty(starts)
    # Should be one frame at the coord's own TO (cur_id=0), which is
    # t = 2µs beacon + 1ns syncing = 2.000001µs. Plus the COMMIT signal
    # duration ≈ 0 in our simplified model — PLCA fires COMMIT then
    # immediately TX on the same simtime.
    @test starts[1][4] == to_simtime(2e-6) + to_simtime(1e-9)
    @test starts[1][2] === frame
    # ends match starts
    ends = filter(f -> f[1] === :end_frame, frames)
    @test Base.length(ends) == 1
    # tx duration = 584 bits / 10 Mb = 58.4 µs
    @test ends[1][2] - starts[1][4] == to_simtime(584 / 10e6)
end

# --- Packet arrives well before own TO — DS_HOLD holds it ------------------

@testset "packet arrives early, waits in HOLD until own TO" begin
    sim = _build_sim(2)
    sigs = Any[]
    frames = Any[]
    plca_ref = Ref{PlcaState}()
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0);
                     downlink = _looped_recording_downlink(plca_ref, sigs, frames),
                     upcalls = default_plca_upcalls())
    plca_ref[] = plca

    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    # Configure so the coord's own TO is NOT the first one — set local_id=1
    # on a follower... but followers require BEACON arrival. Simpler: keep
    # coord, and verify the packet arrives AFTER the coord's first BEACON is
    # sent so the coord is in WAIT_TO by then.
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    run!(sim)

    # DS_HOLD should have held the packet across the BEACON emission
    # (2 µs) and the SYNCING gap (1 ns), then transmitted at t = 2µs + 1 ns.
    starts = filter(f -> f[1] === :start_frame, frames)
    @test Base.length(starts) >= 1
    @test starts[1][4] == to_simtime(2e-6) + to_simtime(1e-9)
end

# --- data FSM state accessor -------------------------------------------------

@testset "plca_data(plca) returns a stable per-PLCA data FSM" begin
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0))
    d1 = plca_data(plca)
    d2 = plca_data(plca)
    @test d1 === d2
    @test d1.ds === DS_IDLE
end
