module InetCommon

# ============================================================================
# `InetCommon` — the infrastructure the model libraries share.
#
# Module lookup: how a module gets hold of another that offers an interface, by
# walking the connections or by evaluating a reference. It is independent of
# what is being looked for — the queuing contract and the protocol models are
# both consumers — which is why it lives below both rather than inside either.
# Design: plan/pending/queuing-model-migration.md §3.5.
# ============================================================================

include("lookup/Lookup.jl")
using .LookupModule

export LookupModule

end # module InetCommon
