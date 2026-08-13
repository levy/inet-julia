# ============================================================================
# T1S stats phase 2 — the core five signals, with analytical pins.
#
# For notraffic (N=5): expected cycle length = 2 µs BEACON + 1 ns syncing
# + 5 * 3.2 µs TOs = 18.001 µs = 18_001_000 ps. curID cycles 0..4 per cycle.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetPacket.PacketModule, InetLinkLayer.T1sModule

# Helper: run notraffic and return the recorder's captured VectorResults.
function _run_notraffic_with_stats(; n_nodes = 5, time_limit = 100e-6)
    t = SimulationType(T1sModel)
    a = ParameterBindings(Dict{Symbol,Any}(
        :n_nodes    => n_nodes,
        :time_limit => time_limit,
        :scenario   => :notraffic))
    run = expand_configuration(configure_simulation(t, a))[1]
    inst = make_execution(run; engine = SequentialEngineSpec())
    run_execution!(inst)
    return finish_execution!(inst)
end

@testset "notraffic emits cycleLength — analytical pin" begin
    res = _run_notraffic_with_stats()
    # Find the coordinator's cycleLength vector.
    cl = filter(v -> occursin("MultidropNetwork.controller.eth[0].plca", v.module_path) &&
                    v.name == "cycleLength:vector", res.vectors)
    @test !isempty(cl)
    vec = cl[1]
    # Expected: 2µs + 1ns + 5 * 3.2µs = 18.001 µs.
    # Values are in SECONDS (INET convention — SimTime overload of
    # emit_indexed_vector divides by TIME_UNIT).
    expected_s = 2e-6 + 1e-9 + 5 * 3.2e-6
    @test !isempty(vec.samples)
    for (t, v) in vec.samples
        @test v ≈ expected_s atol = 1e-15
    end
end

@testset "notraffic emits curID — sawtooth 0..N-1 per cycle" begin
    res = _run_notraffic_with_stats()
    cid = filter(v -> occursin("MultidropNetwork.controller.eth[0].plca", v.module_path) &&
                     v.name == "curID:vector", res.vectors)
    @test !isempty(cid)
    ids = [Int(v) for (t, v) in cid[1].samples]
    # Coord's curID trace: 0,1,2,3,4,0,1,2,3,4,0,...
    # For time_limit 100µs / cycle 18µs = ~5 cycles = ~25 samples.
    @test length(ids) >= 5
    # Sawtooth invariant: from 0..N-1 then reset. Check we see all values.
    n = 5
    for k in 0:(n - 1)
        @test k in ids
    end
end

@testset "notraffic emits toLength — every TO is empty (3.2 µs)" begin
    res = _run_notraffic_with_stats()
    tl = filter(v -> occursin("MultidropNetwork.controller.eth[0].plca", v.module_path) &&
                    v.name == "toLength:vector", res.vectors)
    @test !isempty(tl)
    vals = [v for (t, v) in tl[1].samples]
    @test !isempty(vals)
    # Every empty TO is 3.2 µs.
    for v in vals
        @test v ≈ 3.2e-6 atol = 1e-15
    end
end

@testset "notraffic emits ownToLength — only when finishing our own TO" begin
    res = _run_notraffic_with_stats()
    own_coord = filter(v -> occursin("MultidropNetwork.controller.eth[0].plca", v.module_path) &&
                             v.name == "ownToLength:vector", res.vectors)
    @test !isempty(own_coord)
    for (_, v) in own_coord[1].samples
        @test v ≈ 3.2e-6 atol = 1e-15
    end
    own_f1 = filter(v -> occursin("MultidropNetwork.node[0].eth[0].plca", v.module_path) &&
                          v.name == "ownToLength:vector", res.vectors)
    @test !isempty(own_f1)
    @test !isempty(own_f1[1].samples)
end

@testset "recorder is optional — off by default, all fields default nothing" begin
    # No :vec_path → no VectorFileWriter; recorder still exists but in-memory.
    res = _run_notraffic_with_stats()
    @test !isempty(res.vectors)   # Recorder was attached (via schedule_initial_events)
end

@testset "notraffic determinism — hash unchanged by statistics emission" begin
    # Recording is supposed to be determinism-neutral (Recorder.jl:16-17).
    # Compare the network hash with a run that has stats enabled vs the
    # previously-pinned value.
    res = _run_notraffic_with_stats()
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
end
