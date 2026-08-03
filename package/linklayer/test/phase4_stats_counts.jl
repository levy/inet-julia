# ============================================================================
# T1S stats phase 4 — per-cycle / per-TO counts.
# transmitOpportunityUsed (0 on YIELD, 1 on TRANSMIT-first).
# numPacketsPerTo / numPacketsPerOwnTo / numPacketsPerCycle already emit
# from phase 2's Enter actions.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetPacket.PacketModule, InetLinkLayer.T1sModule

_run_stats() = let t = SimulationType(T1sModel),
                   a = ParameterAssignment(Dict{Symbol,Any}(
                       :n_nodes    => 5,
                       :time_limit => 100e-6,
                       :scenario   => :notraffic)),
                   r = expand_simulation(configure_simulation(t, a))[1],
                   ex = prepare_simulation_execution(r; engine = SequentialEngineSpec())
    run_simulation!(ex)
    finish_simulation!(ex)
end

@testset "notraffic: transmitOpportunityUsed = 0 (every own TO yields)" begin
    res = _run_stats()
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].plca", x.module_path) &&
                     x.name == "transmitOpportunityUsed:vector", res.vectors)
    @test !isempty(v)
    @test !isempty(v[1].samples)
    for (_, val) in v[1].samples
        @test val == 0
    end
end

@testset "notraffic: numPacketsPerTo is 0 for every TO" begin
    res = _run_stats()
    for path in vcat(["MultidropNetwork.controller.eth[0].plca"],
                     ["MultidropNetwork.node[$k].eth[0].plca" for k in 0:3])
        v = filter(x -> x.module_path == path &&
                         x.name == "numPacketsPerTo:vector", res.vectors)
        @test !isempty(v)
        for (_, val) in v[1].samples
            @test val == 0
        end
    end
end

@testset "notraffic: numPacketsPerCycle is 0 per cycle" begin
    res = _run_stats()
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].plca", x.module_path) &&
                     x.name == "numPacketsPerCycle:vector", res.vectors)
    @test !isempty(v)
    @test !isempty(v[1].samples)
    for (_, val) in v[1].samples
        @test val == 0
    end
end

@testset "hash stable under phase 4 emissions" begin
    res = _run_stats()
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
end
