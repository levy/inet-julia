# ============================================================================
# WireJunction — the T-junction that broadcasts a signal to all other ports.
#
# Faithful to INET's `physicallayer/wired/common/WireJunction.cc:83-139`:
# any signal arriving on port K is duplicated to every other port after the
# per-segment propagation delay. Multidrop topologies are CHAINS of
# point-to-point segments joined by these T-junctions (plan §4.2), NOT stars
# from each sender.
#
# Structure:
#
#   Each junction owns a `module_id` (so `schedule!` can target it) and a
#   list of `JunctionPort`s. Each port carries:
#     - peer_module_id  the ID we schedule the delivery callback at
#     - segment_delay   propagation delay to the immediate peer
#     - on_rx_start     closure that delivers to the peer (calls `phy_rx_start!`
#                       if the peer is a PHY, or `junction_receive!` if it's
#                       another junction)
#     - on_rx_update    same for truncation propagation
#
# The wiring code (T1sModel build, Phase 9) constructs the closures, so this
# module doesn't need to know whether a port's peer is a PHY or another
# junction — that's a polymorphism boundary set at build time.
# ============================================================================

struct JunctionPort
    peer_module_id::Int
    segment_delay::SimTime
    on_rx_start::Function       # (ctx, sig) -> called at the peer module
    on_rx_update::Function      # (ctx, sig) -> ditto, for truncations
end

mutable struct WireJunctionState
    module_id::Int
    ports::Vector{JunctionPort}
end

WireJunctionState(module_id::Int) = WireJunctionState(module_id, JunctionPort[])

Base.length(j::WireJunctionState) = Base.length(j.ports)

"""
    junction_add_port!(j, peer_module_id, segment_delay, on_rx_start, on_rx_update)

Append a port. Returns the (1-based) port index — the caller uses this
when delivering signals so the junction knows which port to exclude on
fan-out.
"""
function junction_add_port!(j::WireJunctionState,
                            peer_module_id::Int, segment_delay::SimTime,
                            on_rx_start::Function, on_rx_update::Function)
    push!(j.ports, JunctionPort(peer_module_id, segment_delay, on_rx_start, on_rx_update))
    return Base.length(j.ports)
end

# ---------- receive: fan out to all OTHER ports ------------------------------

"""
    junction_receive!(ctx, j, from_port::Int, sig::WireEvent)

Called synchronously when a signal enters the junction on `from_port`.
Schedules delivery of the signal at every OTHER port's peer, after that
port's `segment_delay`.
"""
function junction_receive!(ctx, j::WireJunctionState, from_port::Int, sig::WireEvent)
    for i in eachindex(j.ports)
        i == from_port && continue
        port = j.ports[i]
        schedule!(ctx, port.segment_delay, port.peer_module_id,
                  function (ctx2) port.on_rx_start(ctx2, sig) end)
    end
    return nothing
end

"""
    junction_update!(ctx, j, from_port::Int, sig::WireEvent)

Truncation propagation. Symmetric to `junction_receive!` but calls each
peer's `on_rx_update` instead. Used when a sending PHY cuts its signal
short (COMMIT truncation, CS_ABORT, etc.).
"""
function junction_update!(ctx, j::WireJunctionState, from_port::Int, sig::WireEvent)
    for i in eachindex(j.ports)
        i == from_port && continue
        port = j.ports[i]
        schedule!(ctx, port.segment_delay, port.peer_module_id,
                  function (ctx2) port.on_rx_update(ctx2, sig) end)
    end
    return nothing
end
