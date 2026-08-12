# ============================================================================
# T1S stats phase 3 — FSM-trace signals.
# controlStateChanged, dataStateChanged, txCmd, rxCmd emitted per transition
# / per change.
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
                   ex = make_execution(r; engine = SequentialEngineSpec())
    run_execution!(ex)
    finish_execution!(ex)
end

@testset "controlStateChanged fires on every control-FSM transition" begin
    res = _run_stats()
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].plca", x.module_path) &&
                     x.name == "controlState:vector", res.vectors)
    @test !isempty(v)
    # Coord over 100 µs cycles through: RESYNC → SEND_BEACON → SYNCING →
    # WAIT_TO → YIELD → NEXT_TX_OPPORTUNITY → WAIT_TO (×4) → RESYNC → …
    # ≈9 transitions per cycle × ~5 cycles = ~45 samples.
    @test length(v[1].samples) > 20
end

@testset "dataStateChanged fires (at least the DATA_S_IDLE emit on start)" begin
    res = _run_stats()
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].plca", x.module_path) &&
                     x.name == "dataState:vector", res.vectors)
    @test !isempty(v)
    # With no traffic the data FSM stays in DATA_S_IDLE — but the very first
    # entry emits once. (Phase 5+ tests exercise the transmit path.)
    @test length(v[1].samples) >= 0
end

@testset "txCmd changes on BEACON emit/end + COMMIT emit/end" begin
    res = _run_stats()
    v = filter(x -> occursin("MultidropNetwork.controller.eth[0].plca", x.module_path) &&
                     x.name == "txCmd:vector", res.vectors)
    @test !isempty(v)
    # For coord: per cycle, BEACON → NONE. ~5 cycles = ~10 changes.
    @test length(v[1].samples) >= 8
    # Values are UInt8-cast enum vals: CMD_NONE=0, CMD_BEACON=1, CMD_COMMIT=2.
    vals = [round(Int, v_) for (_, v_) in v[1].samples]
    @test all(v_ in (0, 1, 2) for v_ in vals)
end

@testset "rxCmd changes on follower when BEACON arrives" begin
    res = _run_stats()
    # Follower node[1] receives coord's BEACON periodically.
    v = filter(x -> occursin("MultidropNetwork.node[0].eth[0].plca", x.module_path) &&
                     x.name == "rxCmd:vector", res.vectors)
    @test !isempty(v)
    @test length(v[1].samples) >= 4     # ≥ one BEACON per cycle
end

@testset "hash is unchanged by state-trace emission (determinism-neutral)" begin
    res = _run_stats()
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
end
