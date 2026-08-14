# ============================================================================
# Phase 8 conformance — App layer (source + sink + queue).
# ============================================================================
using Test
using OmnetppSimulator
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

_build_sim(n::Int) = SequentialEngine(n)

@testset "SourceConfig — fixed interval defaults" begin
    cfg = SourceConfig(dst_address = UInt64(0x1), interval = 5e-6,
                       packet_length = 100)
    @test cfg.interval_kind === IA_FIXED
    @test cfg.dst_address == 0x1
    @test cfg.interval_min == 5e-6 && cfg.interval_max == 5e-6
    @test cfg.packet_length_min == 100 && cfg.packet_length_max == 100
end

@testset "source pushes packets into MAC at fixed interval" begin
    sim = _build_sim(2)
    log = Any[]
    mac = MacState(2, UInt64(0x1);
                   downlink = MacDownlink(
                       (ctx, pk, esd) -> push!(log, (:start_frame, ctx.timestamp, pk)),
                       (ctx)          -> push!(log, (:end_frame, ctx.timestamp)),
                       (ctx, kind)    -> nothing,
                       (ctx)          -> nothing,
                   ))
    src = SourceConfig(dst_address = UInt64(0x2), interval = 100e-6,
                       initial_offset = 0.0, packet_length = 46)
    app = AppState(2, UInt64(0x1); source = src)
    app.mac = mac

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> app_generate!(ctx, app))
    schedule_root!(sim, to_simtime(500e-6), 2,
                   ctx -> stop!(ctx.sim, OmnetppSimulator.LimitReached(:simulation_time)))
    advance_engine!(sim)

    # 500 µs / 100 µs interval = 5 generations at t=0, 100, 200, 300, 400 µs.
    starts = filter(x -> x[1] === :start_frame, log)
    @test Base.length(starts) == 5
    @test starts[1][2] == to_simtime(0.0)
    @test starts[2][2] == to_simtime(100e-6)
    @test starts[end][2] == to_simtime(400e-6)
end

@testset "app_receive counts packets and forwards to sink" begin
    app = AppState(2, UInt64(0x1))
    @test app.packets_received == 0

    payload = Filler(Bytes(46))
    frame = build_ethernet_frame(UInt64(0x99), UInt64(0x1),
                                 ETHERTYPE_IPV4, payload)
    app_receive!(nothing, app, frame)
    app_receive!(nothing, app, frame)
    @test app.packets_received == 2
end
