# Fragment of `LookupModule` — the **default answers**: what a module says when
# it says nothing of its own.

# Most modules have no run state a lookup could depend on, and answer entirely
# through the claims on their gates. Overriding this is for the few that must
# decide in code.
lookup_module_interface(::Any, ::Gate, ::Type, ::Any, ::Int) = USE_GATE_CLAIMS

"""
    provides_interface(m, interface) -> Bool

Whether `m` provides `interface` at all, regardless of where. This is the check
[`resolve_module`](@ref) makes, since a module found by name arrives through no
gate.

Default: true when any of the module's gates claims the interface. A module
providing an interface that no gate carries — storage a parameter names, a
clock — overrides this.
"""
provides_interface(m, interface::Type) =
    any(gate -> claims_interface(gate, interface), module_gates(m))
