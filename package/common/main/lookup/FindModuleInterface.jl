# Fragment of `LookupModule` — the **walk**: following connections until a
# module answers, and the by-reference alternative for modules that are named
# rather than connected.

"""
    find_module_interface(gate, interface; arguments = nothing, direction = 0)
        -> ModuleRef or nothing

Follow the connections leaving `gate` until a module provides `interface`, and
return a [`ModuleRef`](@ref) to it with the propagation delay accumulated on the
way. `nothing` means nothing out there provides it.

The walk goes the way packets travel — forwards out of an output gate, backwards
out of an input gate — which is what `direction = 0` infers; pass `1` or `-1` to
override. Every module along the way is asked in turn, and answers either in
code, through [`lookup_module_interface`](@ref), or as data, through the
[`InterfaceClaim`](@ref)s on the gate the walk arrived at. A module that does
neither is passed straight through, which is what makes compound walls and
uninterested neighbours invisible here.

An answer in code is final, including a refusal: a module that says no ends the
walk rather than deferring to whatever is behind it.
"""
function find_module_interface(gate::Gate, interface::Type;
                               arguments = nothing, direction::Int = 0)
    forward = direction > 0 || (direction == 0 && gate.direction === GateOutput)
    delay = ZERO_DELAY
    current = gate
    while true
        if forward
            next = next_gate(current)
            next === nothing && return nothing
            # The delay belongs to the connection leaving the gate we are on.
            delay += current.delay
        else
            next = previous_gate(current)
            next === nothing && return nothing
            # Walking against the traffic, the connection we cross is the one
            # leaving the gate we are arriving at.
            delay += next.delay
        end
        current = next
        owner = current.owner
        owner === nothing && return nothing

        answer = lookup_module_interface(owner, current, interface, arguments, direction)
        if !(answer isa UseGateClaims)
            answer === nothing && return nothing
            return ModuleRef(answer.target, answer.gate, delay + answer.delay)
        end
        claimed = _claimed_interface(current, interface, arguments, direction)
        claimed === nothing || return ModuleRef(claimed.target, claimed.gate, delay + claimed.delay)
    end
end

# What the claims on one gate answer, or nothing when none of them do.
function _claimed_interface(gate::Gate, interface::Type, arguments, direction::Int)
    for claim in gate_claims(gate)
        _claim_matches(claim, interface, arguments) || continue
        if claim isa ForwardClaim
            # The module answers only if what it forwards to answers; the module
            # itself is still the one found, because packets go through it.
            _forward_resolves(gate, claim, arguments, direction) || continue
        end
        return own_interface(gate)
    end
    nothing
end

function _forward_resolves(gate::Gate, claim::ForwardClaim, arguments, direction::Int)
    owner = gate.owner
    forwards = Gate[g for g in module_gates(owner) if g.name === claim.gate]
    isempty(forwards) &&
        error("find_module_interface: $(module_name(owner)) forwards a claim for " *
              "$(claim.interface) to its :$(claim.gate) gate, which it does not have")
    # A gate vector forwards only if every one of its gates does — a classifier
    # that cannot reach one of its outputs is miswired, not partially usable.
    for forward in forwards
        find_module_interface(forward, claim.forwarded;
                              arguments = arguments, direction = direction) === nothing &&
            return false
    end
    true
end

"""
    resolve_interface(gate, interface; mandatory = true, arguments = nothing, direction = 0)
        -> ModuleRef

[`find_module_interface`](@ref) with an outcome a module can store: the ref it
found, or — when the lookup fails and it was not `mandatory` —
[`NO_MODULE_REF`](@ref).

A mandatory lookup that fails is an error naming the gate and the interface,
because a module whose peer is missing cannot work and should say so while the
network is being built rather than when the first packet arrives.
"""
function resolve_interface(gate::Gate, interface::Type; mandatory::Bool = true, kwargs...)
    ref = find_module_interface(gate, interface; kwargs...)
    ref === nothing || return ref
    mandatory && error("resolve_interface: nothing connected to $(gate_name(gate)) " *
                       "provides $interface")
    NO_MODULE_REF
end

"""
    resolve_module(network, reference, interface; mandatory = true) -> ModuleRef

Find a module by *name* rather than by connection: evaluate `reference` against
the network and check that what it points at provides `interface`.

This is for the modules a parameter names instead of a connection reaching — the
storage a token bucket draws on, a buffer several queues share. A `nothing`
reference resolves to [`NO_MODULE_REF`](@ref), so an optional parameter that was
never set costs no special case at the call site.

The ref carries no gate and no delay: nothing travels along a connection to get
there, the holder simply calls the module.
"""
function resolve_module(network::Network, reference::Reference, interface::Type;
                        mandatory::Bool = true)
    target = try_evaluate_reference(network, reference)
    if target === nothing
        mandatory && error("resolve_module: the reference does not resolve against " *
                           "network $(network.name)")
        return NO_MODULE_REF
    end
    provides_interface(target, interface) ||
        error("resolve_module: $(module_name(target)) does not provide $interface")
    ModuleRef(target, nothing, ZERO_DELAY)
end

function resolve_module(::Network, ::Nothing, interface::Type; mandatory::Bool = false)
    mandatory && error("resolve_module: a reference to a module providing $interface is required")
    NO_MODULE_REF
end
