# ============================================================================
# T1S stats phase 6 — PHY statistics.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetPacket.PacketModule, InetLinkLayer.T1sModule

_run(scenario::Symbol = :notraffic; time_limit = 100e-6) =
    let t = SimulationType(T1sModel),
        a = ParameterBindings(Dict{Symbol,Any}(
                :n_nodes    => 5,
                :time_limit => time_limit,
                :scenario   => scenario)),
        r = expand_configuration(configure_simulation(t, a))[1],
        ex = make_execution(r; engine = SequentialEngineSpec())
        run_execution!(ex)
        finish_execution!(ex)
    end

@testset "notraffic: coord PHY transmissions match beacon cadence" begin
    res = _run(:notraffic)
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].phy", x.module_path) &&
                     x.name == "transmitting:vector", res.vectors)
    @test !isempty(v)
    # Coord emits one BEACON per cycle (~5 over 100 µs).
    @test length(v[1].samples) >= 4

    # transmittedSignalType alternates SIG_BEACON=1 at tx-start and 0 at
    # tx-end, matching INET's on-both-edges pattern.
    v_t = filter(x -> occursin("MultidropNetwork.controller.eth[0].phy", x.module_path) &&
                       x.name == "transmittedSignalType:vector", res.vectors)
    @test !isempty(v_t)
    vals = Set(val for (_, val) in v_t[1].samples)
    @test 0 in vals && 1 in vals
end

@testset "notraffic: follower PHYs receive coord's beacons" begin
    res = _run(:notraffic)
    for k in 0:3
        v = filter(x -> x.module_path == "MultidropNetwork.node[$k].eth[0].phy" &&
                         x.name == "receivedSignalType:vector", res.vectors)
        @test !isempty(v)
        @test length(v[1].samples) >= 4     # one per BEACON received
        # receivedSignalType alternates 1 (BEACON=SIG_BEACON) at rx-start,
        # then 0 at rx-end. Under notraffic we get pairs of (1, 0, 1, 0…).
        vals = [val for (_, val) in v[1].samples]
        @test 1 in vals            # BEACON seen
    end
end

@testset "PHY stateChanged fires" begin
    res = _run(:notraffic)
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].phy", x.module_path) &&
                     x.name == "state:vector", res.vectors)
    @test !isempty(v)
    # Coord: IDLE → TRANSMITTING → CRS_ON → IDLE per beacon.
    @test length(v[1].samples) >= 6
end

@testset "hash unchanged by PHY stats" begin
    res = _run(:notraffic)
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
end
