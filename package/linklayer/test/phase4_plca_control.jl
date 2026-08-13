# ============================================================================
# Phase 4 conformance — PLCA control FSM (14 states).
#
# For Phase 4 the data FSM is inert (packet_pending / TX_EN always false).
# We validate:
#   1. Coordinator alone: emits BEACON on start; cycles curID 0..N-1..0.
#   2. Beacon cadence: cycle time = beacon(2µs) + syncing(1ns) + N * to_timer(3.2µs).
#   3. Follower detects a synthetic BEACON and mirrors the cycle.
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

_build_sim(n::Int) = SequentialSimulator(n)

# Recording downlink for signal-tx observation.
struct RecordedSignalTx
    kind::EthernetSignalKind
    t::SimTime
    endp::Bool                    # true if this is an end_signal_tx call
end

function _recording_downlink(log::Vector{RecordedSignalTx})
    return PlcaDownlink(
        (ctx, kind) -> push!(log, RecordedSignalTx(kind, ctx.timestamp, false)),
        (ctx)       -> push!(log, RecordedSignalTx(SIG_NONE, ctx.timestamp, true)),
        (ctx, pkt, esd) -> nothing,          # frame path — Phase 5
        (ctx)           -> nothing,
    )
end

# For the standalone control-FSM tests, we don't wire PHY. Instead, when
# PLCA calls `downlink.start_signal_tx(SIG_BEACON)`, we ALSO simulate the
# PHY's carrier-sense-start callback synchronously (mirroring what a real
# PHY would do). Same for end.
function _looped_downlink(plca_ref::Ref{PlcaState}, log::Vector{RecordedSignalTx})
    return PlcaDownlink(
        function (ctx, kind)
            push!(log, RecordedSignalTx(kind, ctx.timestamp, false))
            plca_on_carrier_sense_start!(ctx, plca_ref[])
            # Fire reception_start for the kind so rx_cmd is set.
            # (Coord self-transmitting doesn't "receive" its own BEACON, but
            # for follower detection we simulate this on the follower side.)
        end,
        function (ctx)
            push!(log, RecordedSignalTx(SIG_NONE, ctx.timestamp, true))
            plca_on_carrier_sense_end!(ctx, plca_ref[])
        end,
        (ctx, pkt, esd) -> nothing,
        (ctx)           -> nothing,
    )
end

# --- 1. Coordinator alone (looped downlink) ---------------------------------

@testset "coordinator emits BEACON at start" begin
    sim = _build_sim(2)
    log = RecordedSignalTx[]
    plca_ref = Ref{PlcaState}()
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0);
                     downlink = _looped_downlink(plca_ref, log))
    plca_ref[] = plca

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> plca_start!(ctx, plca))
    # Run until 50 µs to see multiple cycles.
    schedule_root!(sim, to_simtime(50e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.LimitReached(:simulation_time)))
    advance_engine!(sim)

    # BEACON emissions
    beacons = filter(r -> r.kind === SIG_BEACON && !r.endp, log)
    @test !isempty(beacons)
    @test beacons[1].t == to_simtime(0.0)         # first at t=0

    # Cycle: 2 µs BEACON + 1 ns syncing + 3 * 3.2 µs TO = 11.601 µs
    if Base.length(beacons) >= 2
        cycle = beacons[2].t - beacons[1].t
        expected = to_simtime(2e-6) + to_simtime(1e-9) + to_simtime(3 * 3.2e-6)
        @test cycle == expected
    end
end

@testset "coordinator cycles curID 0..N-1" begin
    sim = _build_sim(2)
    log = RecordedSignalTx[]
    plca_ref = Ref{PlcaState}()
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 0);
                     downlink = _looped_downlink(plca_ref, log))
    plca_ref[] = plca

    # Capture cur_id at each TO boundary — hook into on_carrier_sense_change
    # via the FSM's own transitions. Simpler: sample at fixed points.
    cur_ids = Int[]
    sample_times = [to_simtime(t) for t in (3e-6, 6e-6, 9e-6, 12e-6, 15e-6)]

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> plca_start!(ctx, plca))
    for t in sample_times
        schedule_root!(sim, t, 2, ctx -> push!(cur_ids, plca.cur_id))
    end
    schedule_root!(sim, to_simtime(50e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.LimitReached(:simulation_time)))
    advance_engine!(sim)

    # Timeline (see plan §5.4):
    # t=0: SEND_BEACON, cur_id=0
    # t=2µs:      beacon_timer → SYNCING, cur_id=0
    # t=2µs+1ns:  SYNCING → WAIT_TO(cur_id=0) → YIELD (own TO, no packet)
    # t=5.201µs:  to_timer → NEXT_TX(cur_id=1) → WAIT_TO(1)
    # t=8.401µs:  to_timer → NEXT_TX(cur_id=2) → WAIT_TO(2)
    # t=11.601µs: to_timer → NEXT_TX(cur_id=3) → RESYNC (coord && >=N)
    #             → SEND_BEACON. cur_id STAYS 3 during BEACON emission —
    #             reset happens at SYNCING → WAIT_TO next cycle.
    # t=13.601µs: beacon_timer → SYNCING
    # t=13.601µs+1ns: SYNCING → WAIT_TO with cur_id=0 (first-TO-start rule)
    #
    # samples:
    #   3µs → 0 (in YIELD)
    #   6µs → 1
    #   9µs → 2
    #  12µs → 3 (in SEND_BEACON of cycle 2; reset pending)
    #  15µs → 0 (post-reset, in YIELD of cycle 2)
    @test cur_ids == [0, 1, 2, 3, 0]
end

# --- 3. Follower detects an incoming BEACON and mirrors the cycle ----------

@testset "follower detects BEACON and enters SYNCING → WAIT_TO" begin
    sim = _build_sim(2)
    log_signals = RecordedSignalTx[]
    plca = PlcaState(2, PlcaConfig(plca_node_count = 3, local_node_id = 1);
                     downlink = _recording_downlink(log_signals))

    # Simulate the follower's PHY reception behaviour by driving PLCA's
    # callbacks directly at scripted times.
    schedule_root!(sim, to_simtime(0.0), 2,   ctx -> plca_start!(ctx, plca))
    # BEACON arrives at t=5µs (some coord over the wire).
    fake_beacon = WireEvent(SIG_BEACON, to_simtime(2e-6), 99)
    schedule_root!(sim, to_simtime(5e-6), 2,
                   ctx -> begin
                       plca_on_carrier_sense_start!(ctx, plca)
                       plca_on_reception_start!(ctx, plca, fake_beacon)
                   end)
    # BEACON ends at t=5µs + 2µs.
    schedule_root!(sim, to_simtime(7e-6), 2,
                   ctx -> begin
                       plca_on_reception_end!(ctx, plca, fake_beacon)
                       plca_on_carrier_sense_end!(ctx, plca)
                   end)
    schedule_root!(sim, to_simtime(20e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.LimitReached(:simulation_time)))

    # Sample follower cur_id at 10µs (should be past its own TO).
    cur_id_at_10 = Ref(-1)
    schedule_root!(sim, to_simtime(10e-6), 2,
                   ctx -> (cur_id_at_10[] = plca.cur_id))
    advance_engine!(sim)

    # Follower starts in RESYNC — no signals emitted from downlink at all
    # (followers don't send BEACON).
    beacons_emitted = filter(r -> r.kind === SIG_BEACON && !r.endp, log_signals)
    @test isempty(beacons_emitted)

    # After detecting BEACON at t=5µs and CRS drop at t=7µs, the follower
    # should have transitioned RESYNC → EARLY_RECEIVE → SYNCING → WAIT_TO
    # with cur_id=0. Then rolling: cur_id=0 through YIELD (or own COMMIT at
    # TO 1), advancing to cur_id=1 at t=7µs+3.2µs=10.2µs.
    # At sample t=10µs, cur_id should still be 0 (we're in YIELD for TO 0
    # since t=7µs+ε and the to_timer for cur_id=0 hasn't fired yet — 7µs
    # + 3.2µs = 10.2µs > 10µs).
    @test cur_id_at_10[] == 0
end
