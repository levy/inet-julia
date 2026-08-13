# ============================================================================
# T1S stats phase 5 — MAC statistics.
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

@testset "notraffic: MAC state stays IDLE; frame counters at 0" begin
    res = _run(:notraffic)
    # Under notraffic no frame ever flows, so numFramesSent stays 0.
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].mac", x.module_path) &&
                     x.name == "numFramesSent:vector", res.vectors)
    @test !isempty(v)
    # No samples emitted (counter never incremented).
    @test isempty(v[1].samples)
end

@testset "bestcase: MAC transmits — numFramesSent > 0" begin
    res = _run(:bestcase, time_limit = 200e-6)
    total_sent = 0
    for path in vcat(["MultidropNetwork.controller.eth[0].mac"],
                     ["MultidropNetwork.node[$k].eth[0].mac" for k in 0:3])
        v = filter(x -> x.module_path == path &&
                         x.name == "numFramesSent:vector", res.vectors)
        !isempty(v) || continue
        s = v[1].samples
        isempty(s) && continue
        total_sent += Int(round(s[end][2]))     # final sample = final count
    end
    # At least one frame sent across the whole model — bestcase's placeholder
    # cadence is generous but each frame occupies ~58µs on-wire, so only a
    # few complete within 200µs.
    @test total_sent >= 1
end

@testset "notraffic: MAC never sees CRS/state change (PLCA carrier_status stays false)" begin
    res = _run(:notraffic)
    # PLCA's carrier_status is derived from DATA_S_HOLD/TRANSMIT/COLLIDE which
    # DATA_S_IDLE-only operation never enters. So MAC stays at MAC_IDLE and
    # sees no CRS transitions — this is the correct INET behaviour, not a
    # missing hook.
    v_crs = filter(x -> occursin("MultidropNetwork.controller.eth[0].mac", x.module_path) &&
                         x.name == "carrierSense:vector", res.vectors)
    @test !isempty(v_crs)
    @test isempty(v_crs[1].samples)

    v_state = filter(x -> occursin("MultidropNetwork.controller.eth[0].mac", x.module_path) &&
                           x.name == "state:vector", res.vectors)
    @test !isempty(v_state)
    @test isempty(v_state[1].samples)
end

@testset "bestcase: MAC CRS + stateChanged fire (frames flow)" begin
    res = _run(:bestcase, time_limit = 200e-6)
    v_crs = filter(x -> occursin("MultidropNetwork.node[0].eth[0].mac", x.module_path) &&
                         x.name == "carrierSense:vector", res.vectors)
    @test !isempty(v_crs)
    # Under bestcase, every transmission by ANY node causes PLCA-fabricated
    # CRS at all peer MACs.
    @test length(v_crs[1].samples) >= 2

    v_state = filter(x -> occursin("MultidropNetwork.node[0].eth[0].mac", x.module_path) &&
                           x.name == "state:vector", res.vectors)
    @test !isempty(v_state)
    @test length(v_state[1].samples) >= 1
end

@testset "hash unchanged by MAC stats emission" begin
    res = _run(:notraffic)
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
end
