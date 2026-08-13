# ============================================================================
# Phase 9 conformance — T1sModel wrapping + golden hashes.
#
# The three target scenarios from the plan:
#   - :notraffic  — coordinator + N-1 followers, no traffic.
#                   Only PLCA control-FSM activity.
#   - :bestcase   — every node has traffic (placeholder fixed 10 µs cadence).
#   - :worstcase  — same topology, follower packet arrives past its own TO
#                   (placeholder — full worstcase-offset scheduling is a
#                   follow-up).
#
# The golden hashes pinned here are this model's own hashes, NOT INET's —
# cross-comparison against INET is the F3 follow-up. What we guarantee is:
# same seed → same hash, repeatably.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

@testset "T1sModel — notraffic pins hash" begin
    t = SimulationType(T1sModel)
    a = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => 5, :time_limit => 100e-6, :scenario => :notraffic))
    run = expand_configuration(configure_simulation(t, a))[1]
    inst = make_execution(run; engine = SequentialEngineSpec())
    run_execution!(inst)
    res = finish_execution!(inst)

    # Pin the golden hash. Any behavioural change to PLCA control FSM /
    # PHY / junction fan-out will shift this.
    @test res.network_hash == 0x429fe1b7ab8d705cbaaa4926d57e103b
    @test total_event_count(simulation_engine(inst)) == 299
end

@testset "T1sModel — notraffic is deterministic across runs" begin
    t = SimulationType(T1sModel)
    a = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => 5, :time_limit => 100e-6, :scenario => :notraffic))
    hashes = UInt128[]
    for _ in 1:3
        run = expand_configuration(configure_simulation(t, a))[1]
        inst = make_execution(run; engine = SequentialEngineSpec())
        run_execution!(inst)
        push!(hashes, finish_execution!(inst).network_hash)
    end
    @test Base.length(unique(hashes)) == 1
end

@testset "T1sModel — n_nodes changes hash" begin
    t = SimulationType(T1sModel)
    hashes = UInt128[]
    for n in (3, 5, 7)
        a = ParameterAssignment(Dict{Symbol,Any}(
            :n_nodes => n, :time_limit => 50e-6, :scenario => :notraffic))
        run = expand_configuration(configure_simulation(t, a))[1]
        inst = make_execution(run; engine = SequentialEngineSpec())
        run_execution!(inst)
        push!(hashes, finish_execution!(inst).network_hash)
    end
    @test Base.length(unique(hashes)) == 3   # each n produces a distinct trace
end

# The `:notraffic` hash above never takes a MAC out of `MAC_IDLE` — with no
# traffic there is nothing for it to do — so it guards the PLCA control FSM and
# the PHY, and nothing else. This scenario is the MAC's guard: over 500 µs the
# followers actually contend and transmit, so every MAC transition the model
# takes is folded into the hash. Run long enough that frames really go out (at
# 100 µs only one does).
@testset "T1sModel — bestcase pins hash (the MAC's guard)" begin
    t = SimulationType(T1sModel)
    a = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => 4, :time_limit => 500e-6, :scenario => :bestcase))
    run = expand_configuration(configure_simulation(t, a))[1]
    inst = make_execution(run; engine = SequentialEngineSpec())
    model = simulation_model(inst)
    run_execution!(inst)
    res = finish_execution!(inst)

    @test res.network_hash == 0x6f8ce88a8da52eab756161a1cd751395
    @test total_event_count(simulation_engine(inst)) == 480
    # The point of the scenario: frames really are transmitted and received,
    # so the hash covers the MAC's transmit path and not only its idle state.
    @test sum(n.mac.num_frames_sent for n in model.state.nodes) == 7
    @test sum(n.mac.num_frames_received for n in model.state.nodes) == 7
end

@testset "T1sModel — model interface plumbs through cleanly" begin
    m = build_model(T1sModel, resolve_parameters(model_parameter_space(T1sModel),
                                                  ParameterAssignment()))
    @test m isa AT1sModel
    @test model_module_count(m) == 1 + 5 + 4    # barrier + 5 nodes + 4 junctions
                                                 # (INET: one junction per follower;
                                                 # coord shares j[0] with node[0])
    @test model_barrier_module(m) == 1
    @test isempty(model_delay_edges(m))         # single-cluster
end
