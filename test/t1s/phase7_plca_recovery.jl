# ============================================================================
# Phase 7 conformance — PLCA data FSM recovery path.
#
# DS_HOLD → DS_COLLIDE → DS_DELAY_PENDING → DS_PENDING → DS_WAIT_MAC →
# DS_TRANSMIT.
#
# We simulate the trigger paths without a full MAC-in-loop, focusing on
# the DS state trajectory and its timing.
# ============================================================================
using Test
using Omnetpp
using Inet.PacketModule
using Inet.T1sModule

_build_sim(n::Int) = SequentialSimulator(n)

@testset "DS_HOLD → DS_COLLIDE via hold_timer expiry" begin
    sim = _build_sim(2)
    plca_ref = Ref{PlcaState}()
    # No looped downlink here — we want to observe DS state without
    # the control FSM getting to CS_COMMIT (which would consume the packet).
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 1);
                     upcalls = default_plca_upcalls())
    plca_ref[] = plca

    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    # Follower: won't receive a BEACON, so CS stays in RESYNC — control FSM
    # never reaches CS_COMMIT. hold_timer will time out → DS_COLLIDE.
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    schedule_root!(sim, to_simtime(0.5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    # Sample the DS state at 45 µs (well past hold_timer default of 40 µs).
    ds_at_45 = Ref{PlcaDataState}(DS_IDLE)
    schedule_root!(sim, to_simtime(45e-6), 2,
                   ctx -> (ds_at_45[] = plca_data(plca).ds))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, Omnetpp.SimTimeLimit))
    run!(sim)

    # After hold_timer (default 40 µs = 400 bits @ 10 Mb), DS_HOLD → DS_COLLIDE.
    # Then DS_COLLIDE waits for END_SIGNAL_TRANSMISSION from MAC (which never
    # comes in this test), so it stays in DS_COLLIDE.
    @test ds_at_45[] === DS_COLLIDE
end

@testset "END_SIGNAL_TRANSMISSION advances DS_COLLIDE → DS_DELAY_PENDING → DS_PENDING" begin
    sim = _build_sim(2)
    plca_ref = Ref{PlcaState}()
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 1);
                     upcalls = default_plca_upcalls())
    plca_ref[] = plca

    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    schedule_root!(sim, to_simtime(0.5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    # Wait past hold_timer, then MAC sends END_SIGNAL (simulating the JAM end).
    schedule_root!(sim, to_simtime(45e-6), 2,
                   ctx -> plca_end_signal_from_mac!(ctx, plca))
    # Sample DS after 51.2 µs (pending_timer duration).
    ds_early = Ref{PlcaDataState}(DS_IDLE)
    ds_late = Ref{PlcaDataState}(DS_IDLE)
    schedule_root!(sim, to_simtime(50e-6), 2,
                   ctx -> (ds_early[] = plca_data(plca).ds))
    schedule_root!(sim, to_simtime(100e-6), 2,
                   ctx -> (ds_late[] = plca_data(plca).ds))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, Omnetpp.SimTimeLimit))
    run!(sim)

    # At t=50µs, we're in DS_DELAY_PENDING (started at t=45µs, pending_timer=51.2µs).
    @test ds_early[] === DS_DELAY_PENDING
    # At t=100µs (45+51.2=96.2), we're in DS_PENDING.
    @test ds_late[] === DS_PENDING
end

@testset "DS_WAIT_MAC + START_FRAME_TRANSMISSION → DS_TRANSMIT" begin
    sim = _build_sim(2)
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0))
    frames_sent = Any[]
    # Downlink records start_frame_tx.
    plca.downlink = PlcaDownlink(
        (ctx, kind) -> nothing,
        (ctx)       -> nothing,
        (ctx, pk, esd) -> push!(frames_sent, (:sent, ctx.timestamp, pk)),
        (ctx)          -> nothing,
    )
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    # Manually push into DS_WAIT_MAC state to test the transition.
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        # Prime the data FSM into DS_PENDING then DS_WAIT_MAC via COMMIT_TO.
        d = plca_data(plca)
        d.ds = DS_PENDING
        plca_commit_to!(ctx, plca)   # DS_PENDING → DS_WAIT_MAC
    end)
    # After some delay, MAC re-tries. plca_start_frame_transmission! in
    # DS_WAIT_MAC → DS_TRANSMIT.
    schedule_root!(sim, to_simtime(5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    schedule_root!(sim, to_simtime(100e-6), 2,
                   ctx -> stop!(ctx.sim, Omnetpp.SimTimeLimit))
    run!(sim)

    # Frame should have been sent from DS_TRANSMIT.
    @test !isempty(frames_sent)
    @test frames_sent[1][2] == to_simtime(5e-6)
end
