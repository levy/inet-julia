# Fragment of `LookupModule` — what can be looked for, what a lookup returns,
# and the one generic a module overrides to answer in code. Default answers
# live in `LookupDefaults.jl`.

"""
    ModuleInterface

Supertype of the interfaces a module can be looked up by.

An interface is a *name for a set of methods*, used as the key of a lookup —
never as a supertype. Julia has single inheritance and these roles combine
freely (a queue is a passive sink on one side and a passive source on the
other, a server is active on both), so a module declares the interfaces it
provides per gate instead of inheriting them, and implements their methods.
"""
abstract type ModuleInterface end

"""
    ModuleRef(target, gate, delay)

The answer to a lookup: the module found, the gate of *its* the lookup arrived
at, and the propagation delay accumulated along the way.

The delay is what tells the holder how to reach the module — zero means a
direct call within the same event, non-zero means the crossing has to be
scheduled. [`NO_MODULE_REF`](@ref) is the unresolved ref, which
[`is_resolved`](@ref) rejects.
"""
struct ModuleRef
    target::Any
    gate::Union{Gate,Nothing}
    delay::SimTime
end

"""
    NO_MODULE_REF

The unresolved reference — what a module holds for a gate whose peer is absent
or not looked up yet.
"""
const NO_MODULE_REF = ModuleRef(nothing, nothing, ZERO_DELAY)

"""
    is_resolved(ref) -> Bool

Whether the reference points at a module.
"""
is_resolved(ref::ModuleRef) = ref.target !== nothing

"""
    resolved_module(ref) -> module

The module the reference points at, or an error when it points at none.
"""
function resolved_module(ref::ModuleRef)
    ref.target === nothing && error("resolved_module: the reference is unresolved")
    ref.target
end

"""
    UseGateClaims

What [`lookup_module_interface`](@ref) returns when a module has no answer of
its own and its gates' [`InterfaceClaim`](@ref)s should be consulted instead.
The singleton is [`USE_GATE_CLAIMS`](@ref).
"""
struct UseGateClaims end

"""
    USE_GATE_CLAIMS

The [`UseGateClaims`](@ref) singleton — the default answer to a lookup.
"""
const USE_GATE_CLAIMS = UseGateClaims()

"""
    lookup_module_interface(m, gate, interface, arguments, direction)

Whether `m` provides `interface` to a lookup that arrived at its `gate`, decided
in code. Override this for a module whose answer depends on run state that no
claim can express — a socket owner that accepts only the packets of the socket
it holds, a dispatcher that answers for whichever module sits behind the right
one of its gates.

Return a [`ModuleRef`](@ref) whose `delay` is measured **from `gate`** (use
[`own_interface`](@ref) to claim the arriving gate itself), or `nothing` to
refuse. Both answers are final: the walk stops, and refusing is not the same as
staying silent. The default answer is [`USE_GATE_CLAIMS`](@ref) — say nothing,
and let the gate's claims speak.
"""
function lookup_module_interface end

"""
    own_interface(gate) -> ModuleRef

The answer "yes, this module, at this gate" — for
[`lookup_module_interface`](@ref) implementations claiming the gate the lookup
arrived at.
"""
own_interface(gate::Gate) = ModuleRef(gate.owner, gate, ZERO_DELAY)
