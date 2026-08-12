# ============================================================================
# Phase 5 — communication capture over the queuing elements
# (omnetpp-julia plan/pending/observable-communication.md, Phase 3).
#
# Every resolved ModuleRef is an observation point; the TappedPacketPeer
# proxy records what crosses push_packet!/pull_packet! and forwards the
# rest. The captured stream must agree exactly with the model's own
# recorded statistics — the packets are counted twice, by two independent
# mechanisms, and the numbers must be the same numbers.
# ============================================================================
using Test
using OmnetppSimulator
using InetQueuing

function _queuing_captured_run(captures::Vector{Capture}; seed = 7, time_limit = 10.0)
    t = SimulationType(QueuingModel)
    a = ParameterAssignment(Dict{Symbol,Any}(:seed => seed, :time_limit => time_limit))
    run = expand_simulation(configure_simulation(t, a))[1]
    ex = make_execution(run; engine = SequentialEngineSpec(),
                                      captures = captures)
    run_execution!(ex)
    (ex, finish_execution!(ex))
end

@testset "queuing capture — ModuleRef seams as observation points" begin
    cap = Capture()
    ex, res = _queuing_captured_run([cap])
    scalars = Dict(res.scalars)

    # Every resolved reference is a point: the packet-flow ones and the
    # flow-control back-references alike, in module order.
    @test [p.path for p in cap.points] == [
        "Queuing.source.consumer", "Queuing.queue.producer",
        "Queuing.queue.collector", "Queuing.server.provider",
        "Queuing.server.consumer", "Queuing.sink.producer"]

    counts = Dict{String,Int}()
    for id in cap.buffer.point_ids
        p = capture_point(cap, Int(id))
        counts[p.path] = get(counts, p.path, 0) + 1
    end
    # The captured stream and the model's statistics are the same numbers:
    # pushes into the queue = packets produced; pulls by the server sit
    # between produced and delivered; pushes into the sink = delivered.
    produced  = scalars[Symbol("Queuing.source.packets:count")]
    delivered = scalars[Symbol("Queuing.sink.packets:count")]
    @test counts["Queuing.source.consumer"] == produced
    @test counts["Queuing.server.consumer"] == delivered
    @test delivered <= counts["Queuing.server.provider"] <= produced
    # Flow-control-only references carried nothing — the seam exists, no
    # packet crossed it.
    @test !haskey(counts, "Queuing.queue.producer")
    @test !haskey(counts, "Queuing.queue.collector")
    @test !haskey(counts, "Queuing.sink.producer")

    # Determinism: bit-identical to the uncaptured run.
    ex0, _ = _queuing_captured_run(Capture[])
    @test network_hash(ex.engine) == network_hash(ex0.engine)
    @test total_event_count(ex.engine) == total_event_count(ex0.engine)

    # Zero interposition when off: the uncaptured model's references hold
    # the real modules, not proxies.
    for mod in OmnetppSimulator.NetworkModule.network_modules(ex0.instance.model.network)
        for f in fieldnames(typeof(mod))
            ref = getfield(mod, f)
            hasproperty(ref, :target) || continue
            @test !(ref.target isa InetQueuing.TappedPacketPeer)
        end
    end
end

@testset "queuing capture — scope helpers" begin
    # scope_seam: one seam kind across the network; scope_subtree: one
    # module's subtree. Both are ordinary predicates over the point path.
    by_seam    = Capture(scope = scope_seam("consumer"))
    by_subtree = Capture(scope = scope_subtree("Queuing.server"))
    _, res = _queuing_captured_run([by_seam, by_subtree])
    scalars = Dict(res.scalars)
    produced  = scalars[Symbol("Queuing.source.packets:count")]
    delivered = scalars[Symbol("Queuing.sink.packets:count")]

    @test [p.path for p in by_seam.points] ==
          ["Queuing.source.consumer", "Queuing.server.consumer"]
    @test capture_count(by_seam) == produced + delivered

    @test [p.path for p in by_subtree.points] ==
          ["Queuing.server.provider", "Queuing.server.consumer"]
    @test all(startswith(capture_point(by_subtree, Int(id)).path, "Queuing.server")
              for id in by_subtree.buffer.point_ids)
end
