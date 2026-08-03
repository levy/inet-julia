# Fragment of `PacketProtocolModule` — what a module need not say itself: the
# notifications only streaming cares about, the calls made through a resolved
# reference, the one place that decides between a direct call and a scheduled
# one, and the wiring check.

# Completion notifications matter to streaming and preemption, where a packet is
# handed over in pieces and a transfer can fail part-way. For a whole packet,
# `push_packet!` returning IS the completion, so a module that does not stream
# has nothing to do here.
handle_push_packet_processed!(::Any, ::Any, ::Gate, ::Packet, ::Bool) = nothing
handle_pull_packet_processed!(::Any, ::Any, ::Gate, ::Packet, ::Bool) = nothing

# ── Calling through a resolved reference ───────────────────────────────────
#
# A module keeps its peers as `ModuleRef`s, found once while the network is
# initialized. These forward to the peer at the gate the lookup arrived at, so
# an element writes `can_push_packet(m.consumer, packet)` and never repeats the
# unpacking.
#
# An unresolved reference is a wiring mistake that initialization should already
# have reported, so meeting one here is an error rather than a quiet false.

function _peer(ref::ModuleRef, what::AbstractString)
    is_resolved(ref) ||
        error("$what: the peer reference is unresolved — the module was not " *
              "initialized, or its lookup was optional and found nothing")
    ref
end

can_push_some_packet(ref::ModuleRef) =
    (r = _peer(ref, "can_push_some_packet"); can_push_some_packet(r.target, r.gate))
can_push_packet(ref::ModuleRef, packet::Packet) =
    (r = _peer(ref, "can_push_packet"); can_push_packet(r.target, r.gate, packet))
can_pull_some_packet(ref::ModuleRef) =
    (r = _peer(ref, "can_pull_some_packet"); can_pull_some_packet(r.target, r.gate))
can_pull_packet(ref::ModuleRef) =
    (r = _peer(ref, "can_pull_packet"); can_pull_packet(r.target, r.gate))
pull_packet!(ctx, ref::ModuleRef) =
    (r = _peer(ref, "pull_packet!"); pull_packet!(ctx, r.target, r.gate))
handle_can_push_packet_changed!(ctx, ref::ModuleRef) =
    (r = _peer(ref, "handle_can_push_packet_changed!"); handle_can_push_packet_changed!(ctx, r.target, r.gate))
handle_can_pull_packet_changed!(ctx, ref::ModuleRef) =
    (r = _peer(ref, "handle_can_pull_packet_changed!"); handle_can_pull_packet_changed!(ctx, r.target, r.gate))

"""
    push_or_schedule!(ctx, ref, packet) -> nothing

Deliver `packet` to the consumer `ref` points at, the way the connection to it
requires.

Over an ideal connection that is a direct call, inside the caller's own event:
the packet crosses the whole chain of modules in one event, the way a call
crosses a stack, and no zero-delay events appear in the simulation. Over a
connection with a propagation delay the crossing is a scheduled event instead,
which is what a real link is.

Both cases look the same at the call site, so an element pushes onward without
knowing which kind of connection it is wired to.
"""
function push_or_schedule!(ctx, ref::ModuleRef, packet::Packet)
    peer = _peer(ref, "push_or_schedule!")
    target, gate = peer.target, peer.gate
    if peer.delay == ZERO_DELAY
        push_packet!(ctx, target, gate, packet)
    else
        schedule!(ctx, peer.delay, module_id(target),
                  c -> push_packet!(c, target, gate, packet))
    end
    nothing
end

# ── Wiring ─────────────────────────────────────────────────────────────────

"""
    check_packet_connections(network) -> network

Check that every packet connection has a driver at one end and a passive peer
at the other, and report the ones that do not while the network is being built
rather than when the first packet moves.

Two things go wrong often enough to be worth naming. A connection whose ends
disagree about who drives — both sides waiting to be told, or both trying to
drive — moves no packets at all and looks like a model that simply does
nothing. And a pull connection with a propagation delay is a contradiction: a
pull is a call that returns a packet, so there is nowhere to put a delay; the
delay belongs on the push side, or in a server's processing time.
"""
function check_packet_connections(network::Network)
    for m in network_modules(network)
        for gate in module_gates(m)
            gate.direction === GateOutput || continue
            next_gate(gate) === nothing && continue
            pushes = claims_interface(gate, ActivePacketSource)
            pulled = claims_interface(gate, PassivePacketSource)
            pushes && pulled &&
                error("check_packet_connections: $(gate_name(gate)) claims to both " *
                      "push packets and be pulled from — one connection has one driver")
            if pushes
                find_module_interface(gate, PassivePacketSink) === nothing &&
                    error("check_packet_connections: $(gate_name(gate)) pushes packets, " *
                          "but nothing it is connected to accepts a push — is the far " *
                          "end waiting to pull instead?")
            elseif pulled
                collector = find_module_interface(gate, ActivePacketSink)
                collector === nothing &&
                    error("check_packet_connections: $(gate_name(gate)) is meant to be " *
                          "pulled from, but nothing it is connected to pulls — is the far " *
                          "end waiting to be pushed into instead?")
                collector.delay == ZERO_DELAY ||
                    error("check_packet_connections: $(gate_name(gate)) is pulled from " *
                          "across a connection with a propagation delay, which a pull " *
                          "cannot cross — put the delay on a push connection, or model " *
                          "it as processing time")
            end
        end
    end
    network
end
