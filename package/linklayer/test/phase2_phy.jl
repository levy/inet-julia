# ============================================================================
# Phase 2 conformance — WireEvent + PHY 5-state FSM.
#
# PHY is driven inside a SequentialSimulator; the ScheduleContext plumbing
# is real. Upcalls and downlink are recording stubs so we can inspect what
# PHY told the layer above / the wire.
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

# --- helpers ---------------------------------------------------------------

# Build a tiny sim with 2 modules (module 1 = barrier convention, PHY at 2).
_build_sim() = SequentialSimulator(2)
_run!(sim) = (run!(sim); total_event_count(sim))

# NOTE on style: `schedule_root!` / `schedule!` want the action function as
# the LAST positional arg, so we can't use Julia's `do`-block sugar (which
# would put the closure as the FIRST arg). Explicit lambdas throughout.

# --- WireEvent basic shape --------------------------------------------------

@testset "WireEvent + enums" begin
    @test SIG_NONE === EthernetSignalKind(0)
    @test SIG_DATA === EthernetSignalKind(3)
    @test Int(ESD_BRS) == 1
    @test Int(ESD_NONE) == -1

    sig = WireEvent(SIG_BEACON, to_simtime(2e-6), 5)
    @test sig.kind === SIG_BEACON
    @test sig.packet === nothing
    @test sig.duration == to_simtime(2e-6)
    @test sig.src_module_id == 5
    @test sig.esd === ESD_NONE
    @test !sig.bit_error
end

# --- TimerHandle cancellation semantics --------------------------------------

@testset "TimerHandle — cancel supersedes pending" begin
    sim = _build_sim()
    fired = Ref(0)
    h = TimerHandle()
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        schedule_timer!(ctx, to_simtime(1e-6), 2, h, _ -> (fired[] += 1))
        cancel!(h)
    end)
    _run!(sim)
    @test fired[] == 0

    sim2 = _build_sim()
    fired2 = Ref(0)
    h2 = TimerHandle()
    schedule_root!(sim2, to_simtime(0.0), 2, ctx -> begin
        schedule_timer!(ctx, to_simtime(1e-6), 2, h2, _ -> (fired2[] += 1))
    end)
    _run!(sim2)
    @test fired2[] == 1
    @test !is_scheduled(h2)
end

@testset "TimerHandle — reschedule replaces old" begin
    sim = _build_sim()
    log = SimTime[]
    h = TimerHandle()
    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        schedule_timer!(ctx, to_simtime(1e-6), 2, h, c -> push!(log, c.timestamp))
        schedule_timer!(ctx, to_simtime(2e-6), 2, h, c -> push!(log, c.timestamp))
    end)
    _run!(sim)
    @test log == [to_simtime(2e-6)]
end

# --- PHY: IDLE → TRANSMITTING → CRS_ON → IDLE (frame path) ------------------

@testset "PHY — start frame tx, tx_end, crs_off → IDLE" begin
    sim = _build_sim()
    log = Any[]
    phy = PhyState(2; upcalls = recording_upcalls(log))
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        phy_start_frame_transmission!(ctx, phy, frame, ESD_ESD)
        # MAC would call end at (64+64+8)*8 / bitrate = actually just data bits:
        # dataBits(64B*8=512) + PHY hdr(64) + ESD(8) = 584 bits @ 10 Mb = 58.4 µs
        schedule!(ctx, to_simtime(584 / 10e6), 2,
                  ctx2 -> phy_end_frame_transmission!(ctx2, phy))
    end)
    _run!(sim)

    @test phy.fsm === PHY_IDLE
    kinds = [x[1] for x in log]
    @test kinds == [:carrier_sense_start, :carrier_sense_end]
    @test log[1][2] == to_simtime(0.0)
    @test log[2][2] == to_simtime(584 / 10e6)
end

# --- PHY: RX_START → RECEIVING → RX_END → CRS_ON → IDLE --------------------

@testset "PHY — synthetic rx from peer, deliver at rx_end" begin
    sim = _build_sim()
    log = Any[]
    phy = PhyState(2; upcalls = recording_upcalls(log))
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(3), UInt64(2), ETHERTYPE_IPV4, payload)
    sig = WireEvent(SIG_DATA, frame, ESD_ESD, to_simtime(584 / 10e6), 99, false)

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_rx_start!(ctx, phy, sig))
    _run!(sim)

    @test phy.fsm === PHY_IDLE
    kinds = [x[1] for x in log]
    @test kinds == [:carrier_sense_start, :reception_start, :reception_end,
                    :carrier_sense_end]
    @test log[3][3] === sig
end

# --- Rejects self-rx defensively --------------------------------------------

@testset "PHY — rx from self is ignored" begin
    sim = _build_sim()
    log = Any[]
    phy = PhyState(2; upcalls = recording_upcalls(log))
    self_sig = WireEvent(SIG_DATA, nothing, ESD_NONE, to_simtime(1e-6), 2, false)
    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_rx_start!(ctx, phy, self_sig))
    _run!(sim)
    @test isempty(log)
    @test phy.fsm === PHY_IDLE
end

# --- Collision: TRANSMITTING + RX_START → COLLISION -------------------------

@testset "PHY — collision when rx arrives during tx" begin
    sim = _build_sim()
    log = Any[]
    phy = PhyState(2; upcalls = recording_upcalls(log))
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)
    peer_sig = WireEvent(SIG_DATA, frame, ESD_ESD, to_simtime(584 / 10e6), 99, false)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        phy_start_frame_transmission!(ctx, phy, frame, ESD_ESD)
        schedule!(ctx, to_simtime(10e-6), 2,
                  ctx2 -> phy_rx_start!(ctx2, phy, peer_sig))
        schedule!(ctx, to_simtime(584 / 10e6), 2,
                  ctx2 -> phy_end_frame_transmission!(ctx2, phy))
    end)
    _run!(sim)

    kinds = [x[1] for x in log]
    @test :carrier_sense_start in kinds
    @test :collision_start     in kinds
    @test :collision_end       in kinds
    @test !(:reception_end in kinds)
    @test phy.fsm === PHY_IDLE
end

# --- Downlink: sends the signal to the wire ---------------------------------

@testset "PHY — downlink.send_signal receives our signal" begin
    sim = _build_sim()
    sent = WireEvent[]
    downlink = PhyDownlink(
        (ctx, sig) -> push!(sent, sig),
        (ctx, sig) -> push!(sent, sig),
    )
    phy = PhyState(2; downlink = downlink)
    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_start_signal_transmission!(ctx, phy, SIG_BEACON))
    _run!(sim)

    @test Base.length(sent) == 1
    @test sent[1].kind === SIG_BEACON
    @test sent[1].duration == to_simtime(20 / 10e6)
end
