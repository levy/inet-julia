# ============================================================================
# Phase 6 conformance — MAC 6-state FSM.
#
# JAMMING/BACKOFF paths get unit-test coverage but are only really exercised
# in Phase 7 (DATA_S_COLLIDE closes the loop). Phase 6 focuses on the tx path.
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

_build_sim(n::Int) = SequentialSimulator(n)

# Recording downlink to observe MAC's calls into PLCA.
function _rec_mac_downlink(log::Vector)
    return MacDownlink(
        (ctx, pk, esd) -> push!(log, (:start_frame, ctx.timestamp, pk, esd)),
        (ctx)           -> push!(log, (:end_frame,  ctx.timestamp)),
        (ctx, kind)     -> push!(log, (:start_signal, ctx.timestamp, kind)),
        (ctx)           -> push!(log, (:end_signal,  ctx.timestamp)),
    )
end

@testset "MAC — start/end tx via downlink" begin
    sim = _build_sim(2)
    log = Any[]
    mac = MacState(2, UInt64(0x0102_03040506); downlink = _rec_mac_downlink(log))
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(0x0102_03040506), UInt64(0x0A0B_0C0D0E0F),
                                 ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> mac_upper_packet!(ctx, mac, frame))
    schedule_root!(sim, to_simtime(200e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    advance_engine!(sim)

    # MAC should have started tx immediately, then ended after tx_bits/bitrate.
    starts = filter(x -> x[1] === :start_frame, log)
    ends = filter(x -> x[1] === :end_frame, log)
    @test Base.length(starts) == 1
    @test Base.length(ends) == 1
    @test starts[1][2] == to_simtime(0.0)
    # tx_bits = 64B*8 + phy_hdr(64) + phy_esd(8) = 584 bits @ 10 Mb = 58.4 µs
    @test ends[1][2] - starts[1][2] == to_simtime(584 / 10e6)
    # MAC returns to WAIT_IFG then IDLE after ifg (9.6 µs).
    # At t = end + 9.6 µs, fsm should be IDLE.
    @test fsm_state(mac.fsm_mac) == MAC_S_IDLE
end

@testset "MAC — carrier from PLCA moves us to RECEIVING" begin
    sim = _build_sim(2)
    mac = MacState(2, UInt64(0x1))
    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> mac_handle_carrier_sense_start!(ctx, mac))
    advance_engine!(sim)
    @test fsm_state(mac.fsm_mac) == MAC_S_RECEIVING
    @test mac.carrier_sense == true
end

@testset "MAC — reception_end delivers to app if addressed to us" begin
    sim = _build_sim(2)
    delivered = Any[]
    my_addr = UInt64(0x0A0B_0C0D0E0F)
    mac = MacState(2, my_addr;
                   upcalls = MacUpcalls((ctx, m, pk) -> push!(delivered, pk),
                                        (ctx, m) -> nothing))
    payload = Filler(Bytes(46))
    # Frame TO us.
    frame_us = build_ethernet_frame(UInt64(0x1), my_addr, ETHERTYPE_IPV4, payload)
    # Frame to someone else.
    frame_other = build_ethernet_frame(UInt64(0x1), UInt64(0xDEAD), ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        mac_handle_reception_end!(ctx, mac, SIG_DATA, frame_us)
        mac_handle_reception_end!(ctx, mac, SIG_DATA, frame_other)
    end)
    advance_engine!(sim)

    @test Base.length(delivered) == 1
    @test delivered[1] === frame_us
end

@testset "MAC — JAM path (unit test only, DATA_S_COLLIDE not present in phase 6)" begin
    sim = _build_sim(2)
    log = Any[]
    mac = MacState(2, UInt64(0x1); downlink = _rec_mac_downlink(log), seed = 42)
    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(0x1), UInt64(0x2), ETHERTYPE_IPV4, payload)

    schedule_root!(sim, to_simtime(0.0), 2, ctx -> begin
        mac_upper_packet!(ctx, mac, frame)
        # Simulate a collision arriving 10 µs into tx (PLCA would signal this).
        schedule_event!(ctx, to_simtime(10e-6), 2,
                  ctx2 -> mac_handle_collision_start!(ctx2, mac))
    end)
    schedule_root!(sim, to_simtime(500e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.SimTimeLimit))
    advance_engine!(sim)

    # Sequence: start_frame → (collision at 10µs) → end_frame → start_signal(JAM)
    #           → end_signal (after 3.2µs) → BACKOFF (random 0..1 slot times)
    #           → (backoff expires) → WAIT_IFG → new start_frame (retry)
    starts = filter(x -> x[1] === :start_frame, log)
    end_frames = filter(x -> x[1] === :end_frame, log)
    starts_jam = filter(x -> x[1] === :start_signal && x[3] === SIG_JAM, log)
    ends_signal = filter(x -> x[1] === :end_signal, log)
    @test Base.length(starts) >= 1                # initial tx
    @test Base.length(end_frames) >= 1            # end_frame from collision abort
    @test Base.length(starts_jam) == 1            # JAM signal fired
    @test Base.length(ends_signal) == 1
    # JAM ended 3.2µs after starting.
    @test ends_signal[1][2] - starts_jam[1][2] == to_simtime(3.2e-6)
end
