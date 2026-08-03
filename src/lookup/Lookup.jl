"""
    LookupModule

**Finding the module behind a gate** — how one module gets hold of another
without being told where it is.

A model is wired with connections, but a connection only says which gates are
joined. What a module actually needs is the module *at the other end that
offers a particular interface* — the next thing that will accept a packet, the
storage that holds its tokens — and that module is rarely the immediate
neighbour: compound walls, transparent elements and dispatchers sit in between.
Lookup answers that question, and it is deliberately a mechanism of its own,
separate from the interfaces it finds and from anything that later travels
along the connection.

Two ways to ask:

  * [`find_module_interface`](@ref) walks the chain of connections leaving a
    gate and asks each module on the way whether it provides the interface. A
    module answers either by [`lookup_module_interface`](@ref), deciding in
    code, or by the [`InterfaceClaim`](@ref)s its gates carry, which state the
    same thing as data. A [`ForwardClaim`](@ref) is how a transparent element
    answers on behalf of whatever is behind it.
  * [`resolve_module`](@ref) evaluates a reference against the network, for the
    modules that are named rather than connected — the storage a token bucket
    draws on, a shared buffer.

Both are asked once, while the network is being initialized, and the answer is
kept in a [`ModuleRef`](@ref): a walk per packet would be absurd, and the
topology does not change under a running simulation. The ref carries the
propagation delay accumulated along the way, so its user knows whether reaching
that module means a direct call or a scheduled event.

The module lives in four fragments that share this namespace:
[`LookupInterface.jl`](LookupInterface.jl) declares what a module type may
answer, [`InterfaceClaim.jl`](InterfaceClaim.jl) the claims a gate carries,
[`FindModuleInterface.jl`](FindModuleInterface.jl) the walk itself, and
[`LookupDefaults.jl`](LookupDefaults.jl) the default answers.
"""
module LookupModule

using OmnetppSimulator: SimTime, ZERO_DELAY
using OmnetppSimulator.NetworkModule: Gate, GateInput, GateOutput, Network,
    module_name, module_gates, gate_name, next_gate, previous_gate
using ProjecturedKernel.ReferenceModule: Reference, try_evaluate_reference

export
    # what is being looked for, and what comes back
    ModuleInterface, ModuleRef, NO_MODULE_REF, is_resolved, resolved_module,
    # how a module answers
    lookup_module_interface, UseGateClaims, USE_GATE_CLAIMS, own_interface,
    InterfaceClaim, ForwardClaim, gate_claims, gate_interfaces, claims_interface,
    # asking
    find_module_interface, resolve_interface, resolve_module, provides_interface

include("LookupInterface.jl")
include("InterfaceClaim.jl")
include("FindModuleInterface.jl")
include("LookupDefaults.jl")

end # module
