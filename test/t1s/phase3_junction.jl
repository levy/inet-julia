# ============================================================================
# Phase 3 conformance — WireJunction fan-out + multidrop chain propagation.
#
# The junction has no FSM of its own — it's a pure fan-out primitive.
# Correctness = "signal arrives at each peer at the correct time," where
# "correct" is the sum of segment delays from source to receiver.
# ============================================================================
using Test
using Omnetpp
using Inet.PacketModule
using Inet.T1sModule

# Helper: build a sim with `n` modules — module_ids are 1..n.
_build_sim(n::Int) = SequentialSimulator(n)

# Helper: hook a PHY into a junction port. Returns the port index.
function _wire_phy_to_junction!(j, phy::PhyState, delay::SimTime)
    on_start = (ctx, sig) -> phy_rx_start!(ctx, phy, sig)
    on_update = (ctx, sig) -> phy_rx_update!(ctx, phy, sig)
    return junction_add_port!(j, phy.module_id, delay, on_start, on_update)
end

# Helper: chain two junctions with a segment. Returns the two port indices.
function _wire_junction_pair!(j1, j2, delay::SimTime)
    p1_at_j1 = Ref(0)   # will be filled after adding
    p2_at_j2 = Ref(0)
    p1_at_j1[] = junction_add_port!(j1, j2.module_id, delay,
        (ctx, sig) -> junction_receive!(ctx, j2, p2_at_j2[], sig),
        (ctx, sig) -> junction_update!(ctx, j2, p2_at_j2[], sig))
    p2_at_j2[] = junction_add_port!(j2, j1.module_id, delay,
        (ctx, sig) -> junction_receive!(ctx, j1, p1_at_j1[], sig),
        (ctx, sig) -> junction_update!(ctx, j1, p1_at_j1[], sig))
    return (p1_at_j1[], p2_at_j2[])
end

# --- 2 PHYs + 1 junction: sender through junction to receiver ----------------

@testset "2 nodes + 1 junction — rx arrives after single-hop segment delay" begin
    # Module IDs: 1 = junction, 2 = phy A, 3 = phy B.
    # Segments: A—[100cm]—junction—[50cm]—B. Delay = length_m / 2e8 s/m.
    delay_A = to_simtime(1.0 / 2e8)   # 5 ns
    delay_B = to_simtime(0.5 / 2e8)   # 2.5 ns

    sim = _build_sim(3)
    rx_log = Any[]

    phy_A = PhyState(2)
    phy_B = PhyState(3; upcalls = recording_upcalls(rx_log))
    junction = WireJunctionState(1)

    port_A = _wire_phy_to_junction!(junction, phy_A, delay_A)
    port_B = _wire_phy_to_junction!(junction, phy_B, delay_B)

    # PHY A's downlink routes into the junction on port_A.
    # PHY's downlink must SCHEDULE the junction-receive after its OWN cable
    # delay (segment from PHY to junction). Synchronous would drop that hop.
    phy_A.downlink = PhyDownlink(
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_receive!(ctx2, junction, port_A, sig)),
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_update!(ctx2, junction, port_A, sig)),
    )

    # A transmits a BEACON at t=0. Expected: B sees rx_start at t = delay_A + delay_B = 7.5 ns.
    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_start_signal_transmission!(ctx, phy_A, SIG_BEACON))
    run!(sim)

    # First upcall on B should be reception_start (via carrier_sense_start).
    starts = filter(x -> x[1] === :reception_start, rx_log)
    @test Base.length(starts) == 1
    @test starts[1][2] == delay_A + delay_B
    @test starts[1][3].kind === SIG_BEACON
end

# --- 3 nodes on a shared bus (star) — one junction, three PHYs --------------

@testset "3 PHYs on 1 junction — every peer sees the rx" begin
    delay_A = to_simtime(1e-9)
    delay_B = to_simtime(2e-9)
    delay_C = to_simtime(3e-9)

    sim = _build_sim(4)   # 1 junction + 3 phys
    logB = Any[]
    logC = Any[]

    phy_A = PhyState(2)
    phy_B = PhyState(3; upcalls = recording_upcalls(logB))
    phy_C = PhyState(4; upcalls = recording_upcalls(logC))
    junction = WireJunctionState(1)

    port_A = _wire_phy_to_junction!(junction, phy_A, delay_A)
    port_B = _wire_phy_to_junction!(junction, phy_B, delay_B)
    port_C = _wire_phy_to_junction!(junction, phy_C, delay_C)

    # PHY's downlink must SCHEDULE the junction-receive after its OWN cable
    # delay (segment from PHY to junction). Synchronous would drop that hop.
    phy_A.downlink = PhyDownlink(
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_receive!(ctx2, junction, port_A, sig)),
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_update!(ctx2, junction, port_A, sig)),
    )

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_start_signal_transmission!(ctx, phy_A, SIG_BEACON))
    run!(sim)

    startsB = filter(x -> x[1] === :reception_start, logB)
    startsC = filter(x -> x[1] === :reception_start, logC)
    @test Base.length(startsB) == 1
    @test Base.length(startsC) == 1
    @test startsB[1][2] == delay_A + delay_B
    @test startsC[1][2] == delay_A + delay_C
end

# --- 4-node chain: coord + [j0] + node0 + [j1] + node1 + [j2] + node2 --------

@testset "chain of junctions — cumulative segment delay reaches far end" begin
    # Layout, matching INET's MultidropNetwork.ned:44-49 shape:
    #   coord ---[100cm]--- j0 ---[100cm]--- j1 ---[100cm]--- j2
    #                        |                |                |
    #                     [50cm]           [50cm]           [50cm]
    #                        |                |                |
    #                     node0            node1            node2
    #
    # Module_ids:
    #   1: coord PHY   |  2: j0  |  3: j1  |  4: j2
    #   5: node0 PHY   |  6: node1 PHY  |  7: node2 PHY

    d_seg   = to_simtime(1.00 / 2e8)   # 5 ns   (junction-junction & coord-j0)
    d_stub  = to_simtime(0.50 / 2e8)   # 2.5 ns (junction-node stubs)

    sim = _build_sim(7)
    log_c   = Any[]     # coord
    log_n0  = Any[]
    log_n1  = Any[]
    log_n2  = Any[]

    phy_coord = PhyState(1; upcalls = recording_upcalls(log_c))
    j0        = WireJunctionState(2)
    j1        = WireJunctionState(3)
    j2        = WireJunctionState(4)
    phy_n0    = PhyState(5; upcalls = recording_upcalls(log_n0))
    phy_n1    = PhyState(6; upcalls = recording_upcalls(log_n1))
    phy_n2    = PhyState(7; upcalls = recording_upcalls(log_n2))

    # Wiring — order matters only within a junction (port indices).
    port_c_at_j0    = _wire_phy_to_junction!(j0, phy_coord, d_seg)
    (p_j0_at_j1, p_j1_at_j0)  = _wire_junction_pair!(j0, j1, d_seg)
    (p_j1_at_j2, p_j2_at_j1)  = _wire_junction_pair!(j1, j2, d_seg)
    port_n0_at_j0   = _wire_phy_to_junction!(j0, phy_n0, d_stub)
    port_n1_at_j1   = _wire_phy_to_junction!(j1, phy_n1, d_stub)
    port_n2_at_j2   = _wire_phy_to_junction!(j2, phy_n2, d_stub)

    # Wait — this ordering wires j0's ports as: [coord, j1, n0]. That's fine,
    # they're just indices. Set up downlinks last.
    phy_coord.downlink = PhyDownlink(
        (ctx, sig) -> schedule!(ctx, d_seg, j0.module_id,
                                ctx2 -> junction_receive!(ctx2, j0, port_c_at_j0, sig)),
        (ctx, sig) -> schedule!(ctx, d_seg, j0.module_id,
                                ctx2 -> junction_update!(ctx2, j0, port_c_at_j0, sig)),
    )

    schedule_root!(sim, to_simtime(0.0), 1,
                   ctx -> phy_start_signal_transmission!(ctx, phy_coord, SIG_BEACON))
    run!(sim)

    # Expected rx-start times:
    #   node0: d_seg (coord→j0) + d_stub (j0→n0) = 7.5 ns
    #   node1: d_seg + d_seg (j0→j1) + d_stub    = 12.5 ns
    #   node2: d_seg + d_seg + d_seg + d_stub    = 17.5 ns
    #   coord: no rx (we didn't loopback)
    starts_n0 = filter(x -> x[1] === :reception_start, log_n0)
    starts_n1 = filter(x -> x[1] === :reception_start, log_n1)
    starts_n2 = filter(x -> x[1] === :reception_start, log_n2)
    starts_c  = filter(x -> x[1] === :reception_start, log_c)

    @test Base.length(starts_n0) == 1 && starts_n0[1][2] == d_seg + d_stub
    @test Base.length(starts_n1) == 1 && starts_n1[1][2] == 2*d_seg + d_stub
    @test Base.length(starts_n2) == 1 && starts_n2[1][2] == 3*d_seg + d_stub
    @test isempty(starts_c)
end

# --- Junction fans out to N-1 ports, not N -----------------------------------

@testset "junction excludes the from_port on fan-out" begin
    # 2 PHYs on a junction, A transmits — B receives, A does NOT (no loopback).
    sim = _build_sim(3)
    logA = Any[]
    logB = Any[]

    phy_A = PhyState(2; upcalls = recording_upcalls(logA))
    phy_B = PhyState(3; upcalls = recording_upcalls(logB))
    junction = WireJunctionState(1)

    delay_A = to_simtime(1e-9)
    port_A = _wire_phy_to_junction!(junction, phy_A, delay_A)
    port_B = _wire_phy_to_junction!(junction, phy_B, to_simtime(1e-9))

    # PHY's downlink must SCHEDULE the junction-receive after its OWN cable
    # delay (segment from PHY to junction). Synchronous would drop that hop.
    phy_A.downlink = PhyDownlink(
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_receive!(ctx2, junction, port_A, sig)),
        (ctx, sig) -> schedule!(ctx, delay_A, junction.module_id,
                                ctx2 -> junction_update!(ctx2, junction, port_A, sig)),
    )

    schedule_root!(sim, to_simtime(0.0), 2,
                   ctx -> phy_start_signal_transmission!(ctx, phy_A, SIG_BEACON))
    run!(sim)

    @test isempty(filter(x -> x[1] === :reception_start, logA))
    @test !isempty(filter(x -> x[1] === :reception_start, logB))
end
