# ============================================================================
# Phase 10 — communication capture over the T1S stack
# (omnetpp-julia plan/pending/observable-communication.md, Phase 2).
#
# The stack's boundary slots become observation points with no protocol
# code involved: five per node (mac.service.up, mac.protocol.down,
# plca.protocol.down, phy.wire.down, phy.wire.up). The per-point record
# counts pinned below are this model's own goldens (same convention as
# phase 9's hashes): the 100 µs bestcase run starts one DATA frame at
# node[0] that completes and is delivered to the controller, while
# node[1..3]'s first frames are still held at PLCA (mac.protocol.down = 1,
# plca.protocol.down = 0 — the service/protocol vantage split made
# visible), and the wire points see the beacon/commit/data signals that
# completed by the time limit.
# ============================================================================
using Test
using OmnetppSimulator
using InetLinkLayer
using InetLinkLayer.T1sModule
using InetPacket.PacketModule

# One captured bestcase run (5 nodes, 100 µs), returning (execution, capture).
function _t1s_captured_bestcase(captures::Vector{Capture})
    t = SimulationType(T1sModel)
    a = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => 5, :time_limit => 100e-6, :scenario => :bestcase))
    run = expand_simulation(configure_simulation(t, a))[1]
    ex = prepare_simulation_execution(run; engine = SequentialEngineSpec(),
                                      captures = captures)
    run_simulation!(ex)
    finish_simulation!(ex)
    ex
end

@testset "T1S capture — boundary seams as observation points" begin
    cap = Capture()
    ex  = _t1s_captured_bestcase([cap])

    # 5 seams × 5 nodes, in node order, coordinator first.
    @test length(cap.points) == 25
    @test [p.path for p in cap.points[1:5]] == [
        "MultidropNetwork.controller.eth[0].mac.service.up",
        "MultidropNetwork.controller.eth[0].mac.protocol.down",
        "MultidropNetwork.controller.eth[0].plca.protocol.down",
        "MultidropNetwork.controller.eth[0].phy.wire.down",
        "MultidropNetwork.controller.eth[0].phy.wire.up"]
    @test cap.points[6].path == "MultidropNetwork.node[0].eth[0].mac.service.up"

    # Golden per-point record counts for this run (zero-count points omitted).
    counts = Dict{String,Int}()
    for id in cap.buffer.point_ids
        p = capture_point(cap, Int(id))
        counts[p.path] = get(counts, p.path, 0) + 1
    end
    @test counts == Dict(
        "MultidropNetwork.controller.eth[0].mac.service.up"  => 1,
        "MultidropNetwork.controller.eth[0].phy.wire.down"   => 1,
        "MultidropNetwork.controller.eth[0].phy.wire.up"     => 1,
        "MultidropNetwork.node[0].eth[0].mac.protocol.down"  => 2,
        "MultidropNetwork.node[0].eth[0].plca.protocol.down" => 2,
        "MultidropNetwork.node[0].eth[0].phy.wire.down"      => 3,
        "MultidropNetwork.node[0].eth[0].phy.wire.up"        => 1,
        "MultidropNetwork.node[1].eth[0].mac.protocol.down"  => 1,
        "MultidropNetwork.node[1].eth[0].phy.wire.up"        => 2,
        "MultidropNetwork.node[2].eth[0].mac.protocol.down"  => 1,
        "MultidropNetwork.node[2].eth[0].phy.wire.up"        => 3,
        "MultidropNetwork.node[3].eth[0].mac.protocol.down"  => 1,
        "MultidropNetwork.node[3].eth[0].phy.wire.up"        => 2,
    )

    # The captured stream agrees with the MAC's own counters where the
    # semantics coincide: a service.up record IS a received frame.
    st = ex.instance.model.state
    @test counts["MultidropNetwork.controller.eth[0].mac.service.up"] ==
          st.nodes[1].mac.num_frames_received == 1
    # mac.protocol.down counts frames whose transmission STARTED;
    # num_frames_sent counts completions — starts always dominate.
    @test all(get(counts, "MultidropNetwork.node[$(i-2)].eth[0].mac.protocol.down", 0) >=
              st.nodes[i].mac.num_frames_sent for i in 2:5)

    # Payload types per vantage: packets at protocol/service seams, wire
    # events (beacon/commit/data signals) at the wire seams.
    for i in 1:capture_count(cap)
        r = capture_record(cap, i)
        if occursin(".phy.wire.", r.point.path)
            @test r.payload isa WireEvent
        else
            @test r.payload isa Packet
        end
        @test r.send_time == r.deliver_time      # a hand-off is one moment
    end
    @test issorted(cap.buffer.deliver_times)

    # Determinism: the captured run is bit-identical to an uncaptured one.
    ex0 = _t1s_captured_bestcase(Capture[])
    @test network_hash(ex.engine) == network_hash(ex0.engine)
    @test total_event_count(ex.engine) == total_event_count(ex0.engine)

    # Zero interposition when off: the uncaptured model's slots are the
    # wired originals (taps replace the structs, so identity is the check).
    st0 = ex0.instance.model.state
    @test all(!occursin("record_tap", string(typeof(n.mac.upcalls.frame_received)))
              for n in st0.nodes)
end

@testset "T1S capture — filters, wire signals, notraffic" begin
    # An ordinary predicate scoped to the wire: keep only signals that
    # carry a packet (drop beacon/commit chrome).
    wire_data = Capture(scope  = pt -> endswith(pt.path, "phy.wire.up"),
                        filter = ev -> ev.packet !== nothing)
    _t1s_captured_bestcase([wire_data])
    @test capture_count(wire_data) > 0
    @test all(ev.packet isa Packet for ev in wire_data.buffer.payloads)

    # notraffic: no frames anywhere, but the PLCA cycle is visible on the
    # wire — exactly the "whole network vs one protocol" scaling story.
    t = SimulationType(T1sModel)
    a = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => 5, :time_limit => 100e-6, :scenario => :notraffic))
    cap = Capture()
    ex = prepare_simulation_execution(expand_simulation(configure_simulation(t, a))[1];
                                      captures = [cap])
    run_simulation!(ex); finish_simulation!(ex)
    paths = [capture_point(cap, Int(id)).path for id in cap.buffer.point_ids]
    @test !isempty(paths)
    @test all(occursin(".phy.wire.", p) for p in paths)     # only wire activity
    @test all(ev.packet === nothing for ev in cap.buffer.payloads)
end

@testset "T1S capture — peer vantage derived from the MAC boundaries" begin
    # Scope one protocol's boundary at the two ends: what one MAC handed
    # down pairs with what the peer MAC delivered up — the peer-level
    # exchange, derived from the frame's identity surviving the whole
    # PLCA/PHY/wire crossing. In the 100 µs bestcase exactly one frame
    # completes: node[0]'s first, delivered to the controller.
    cap = Capture(scope = pt -> endswith(pt.path, "mac.protocol.down") ||
                                endswith(pt.path, "mac.service.up"))
    _t1s_captured_bestcase([cap])
    exchanges = peer_exchanges(cap)
    @test length(exchanges) == 1
    sent     = capture_record(cap, exchanges[1].sent)
    received = capture_record(cap, exchanges[1].received)
    @test sent.point.path == "MultidropNetwork.node[0].eth[0].mac.protocol.down"
    @test received.point.path == "MultidropNetwork.controller.eth[0].mac.service.up"
    @test sent.payload === received.payload
    @test sent.deliver_time < received.deliver_time     # the wire crossing took time
end

@testset "T1S capture — pcapng export of the MAC protocol vantage" begin
    mktempdir() do dir
        path = joinpath(dir, "t1s-bestcase.pcapng")
        sink = PcapngSink(path;
                          frame_bytes = pk -> peek(pk, Raw).data,
                          link_type   = LINKTYPE_ETHERNET)
        cap = Capture(scope = pt -> endswith(pt.path, "mac.protocol.down"),
                      sinks = [sink])
        _t1s_captured_bestcase([cap])

        f = read_pcapng(path)
        # One pcapng interface per node's MAC seam, named by its path.
        @test length(f.interfaces) == 5
        @test all(i.link_type == LINKTYPE_ETHERNET for i in f.interfaces)
        @test f.interfaces[1].name == "MultidropNetwork.controller.eth[0].mac.protocol.down"
        # Every captured frame is a packet: 5 minimum-size Ethernet frames.
        @test length(f.packets) == capture_count(cap) == 5
        @test all(length(p.bytes) == 64 for p in f.packets)
        @test [packet_simtime(f.interfaces, p) for p in f.packets] == cap.buffer.deliver_times
        # dst = coordinator (address 0), EtherType 0x0800 — the frames INET's
        # dissectors (tshark) resolve; validated externally in the plan.
        @test all(p.bytes[1:6] == fill(0x00, 6) for p in f.packets)
        @test all(p.bytes[13:14] == UInt8[0x08, 0x00] for p in f.packets)
    end
end
