# Fragment of `LookupModule` — the **claims a gate carries**: a module stating
# as data, rather than in code, which interfaces it offers where. Claims live in
# the gate's `annotations`, which the module layer stores and never reads.

"""
    InterfaceClaim(interface)

"This module provides `interface` here." Put on a gate, it makes the module the
answer to a lookup for that interface arriving at that gate.

This is the ordinary case: a queue claims that packets can be pushed into its
input and pulled from its output, and says so once, where the gate is built.
"""
struct InterfaceClaim
    interface::Type
end

"""
    ForwardClaim(interface, gate; forwarded = interface)

"This module provides `interface` here, as long as something beyond `gate`
does too." Put on a gate, it makes a module answer *on behalf of* what is
behind it.

This is how a transparent element takes part in a lookup. A delayer claims that
packets can be pushed into its input provided something out of its output will
accept them: a producer looking for a sink finds the delayer, pushes into it,
and the delayer passes each packet on — the lookup is answered by the delayer,
and the data path goes through it.

`forwarded` names the interface to look for beyond the gate when it differs
from the one claimed. A queue uses that: a lookup for something to *push into*
is satisfied by a queue as long as something downstream will *pull*, so the
claim is for a passive sink and the forward is for an active sink.
"""
struct ForwardClaim
    interface::Type
    gate::Symbol
    forwarded::Type
end

ForwardClaim(interface::Type, gate::Symbol; forwarded::Type = interface) =
    ForwardClaim(interface, gate, forwarded)

"""
    gate_claims(gate) -> Vector

The claims carried by `gate`, in declaration order. Annotations that are not
claims — a model library may store others — are skipped.
"""
function gate_claims(gate::Gate)
    claims = Any[]
    for annotation in gate.annotations
        (annotation isa InterfaceClaim || annotation isa ForwardClaim) &&
            push!(claims, annotation)
    end
    claims
end

"""
    gate_interfaces(gate) -> Vector{Type}

Every interface `gate` claims, whether directly or by forwarding.
"""
gate_interfaces(gate::Gate) = Type[claim.interface for claim in gate_claims(gate)]

"""
    claims_interface(gate, interface) -> Bool

Whether `gate` carries a claim for `interface`. Used by wiring checks, which
ask what a gate is for without following the connection anywhere.
"""
claims_interface(gate::Gate, interface::Type) =
    any(claim -> claim.interface === interface, gate_claims(gate))

# Whether a claim answers this lookup. Arguments are not part of the vocabulary
# yet — every claim is unconditional — so only the interface is compared, and it
# is compared exactly: a claim for one interface never answers a lookup for
# another. Argument matching (protocol, service, socket) arrives with the first
# element that dispatches on them.
function _claim_matches(claim, interface::Type, arguments)
    claim.interface === interface || return false
    arguments === nothing ||
        error("find_module_interface: lookup arguments are not supported yet " *
              "(got $(typeof(arguments)) looking for $interface)")
    true
end
