# ============================================================================
# Phase 7 conformance — PLCA data FSM recovery path.
#
# DATA_S_HOLD → DATA_S_COLLIDE → DATA_S_DELAY_PENDING → DATA_S_PENDING → DATA_S_WAIT_MAC →
# DATA_S_TRANSMIT.
#
# We simulate the trigger paths without a full MAC-in-loop, focusing on
# the DS state trajectory and its timing.
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

_build_sim(n::Int) = SequentialSimulator(n)

@testset "DATA_S_HOLD → DATA_S_COLLIDE via hold_timer expiry" begin
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
    # never reaches CS_COMMIT. hold_timer will time out → DATA_S_COLLIDE.
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    schedule_root!(sim, to_simtime(0.5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    # Sample the DS state at 45 µs (well past hold_timer default of 40 µs).
    ds_at_45 = Ref{Int32}(DATA_S_IDLE)
    schedule_root!(sim, to_simtime(45e-6), 2,
                   ctx -> (ds_at_45[] = fsm_state(plca.fsm_data)))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    run!(sim)

    # After hold_timer (default 40 µs = 400 bits @ 10 Mb), DATA_S_HOLD → DATA_S_COLLIDE.
    # Then DATA_S_COLLIDE waits for END_SIGNAL_TRANSMISSION from MAC (which never
    # comes in this test), so it stays in DATA_S_COLLIDE.
    @test ds_at_45[] == DATA_S_COLLIDE
end

@testset "END_SIGNAL_TRANSMISSION advances DATA_S_COLLIDE → DATA_S_DELAY_PENDING → DATA_S_PENDING" begin
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
    ds_early = Ref{Int32}(DATA_S_IDLE)
    ds_late = Ref{Int32}(DATA_S_IDLE)
    schedule_root!(sim, to_simtime(50e-6), 2,
                   ctx -> (ds_early[] = fsm_state(plca.fsm_data)))
    schedule_root!(sim, to_simtime(100e-6), 2,
                   ctx -> (ds_late[] = fsm_state(plca.fsm_data)))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    run!(sim)

    # At t=50µs, we're in DATA_S_DELAY_PENDING (started at t=45µs, pending_timer=51.2µs).
    @test ds_early[] == DATA_S_DELAY_PENDING
    # At t=100µs (45+51.2=96.2), we're in DATA_S_PENDING.
    @test ds_late[] == DATA_S_PENDING
end

@testset "DATA_S_WAIT_MAC + START_FRAME_TRANSMISSION → DATA_S_TRANSMIT" begin
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

    # Manually push into DATA_S_WAIT_MAC state to test the transition.
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        # Prime the data FSM into DATA_S_PENDING then DATA_S_WAIT_MAC via COMMIT_TO.
        plca.fsm_data.state = DATA_S_PENDING
        plca_commit_to!(ctx, plca)   # DATA_S_PENDING → DATA_S_WAIT_MAC
    end)
    # After some delay, MAC re-tries. plca_start_frame_transmission! in
    # DATA_S_WAIT_MAC → DATA_S_TRANSMIT.
    schedule_root!(sim, to_simtime(5e-6), 2,
                   ctx -> plca_start_frame_transmission!(ctx, plca, frame))
    schedule_root!(sim, to_simtime(100e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    run!(sim)

    # Frame should have been sent from DATA_S_TRANSMIT.
    @test !isempty(frames_sent)
    @test frames_sent[1][2] == to_simtime(5e-6)
end
