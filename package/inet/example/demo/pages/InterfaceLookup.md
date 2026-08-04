# Finding the module that answers

A protocol module has to reach its peer. In INET that is usually a string path
in a NED parameter — `interfaceTableModule = "^.interfaceTable"` — resolved by
name at initialisation. It works, and it means that moving a module in the
hierarchy breaks a string somewhere else that nothing type-checks.

Here a module finds its peer by **asking the connections**.

```pred-ref
<<definition(file("../../../common/main/lookup/FindModuleInterface.jl"), "find_module_interface")>>
```

The walk goes the way packets travel — forwards out of an output gate,
backwards out of an input gate — and asks each module it reaches whether it
provides the interface. Two things make that more than a graph search.

**A module can answer in code or as data.** `lookup_module_interface` is the
code answer, and a module that has an opinion gives it. Otherwise the walk
reads the [`InterfaceClaim`](@ref)s on the gate it arrived at, which is the
data answer. A module that does neither is passed straight through — which is
exactly what makes a compound module's wall, or an uninterested neighbour,
invisible to the lookup rather than an obstacle in it.

**A refusal is final.** A module that says "no" ends the walk instead of
deferring to whatever is behind it. That is the difference between a lookup
that finds the nearest willing peer and one that finds something several hops
past a module that meant to stop it.

## Forwarding, which is the interesting case

A module can claim an interface it does not itself implement, on the grounds
that what it forwards to does. A classifier claims to be a passive sink because
its outputs lead to passive sinks; a compound module claims what is inside it.

The claim only holds if the forwarding actually resolves — and for a gate
vector, it holds only if *every* gate resolves, because a classifier that
cannot reach one of its outputs is miswired rather than partially usable. That
check is a recursive `find_module_interface` on each forwarded gate.

The delay accumulates along the way, so what comes back is not just "that
module" but "that module, this far away" — and the propagation delay a
connection carries is picked up from the right side depending on which
direction the walk is going.

## What this buys

It is one small page, and it closes this catalog on an architectural note.

The queueing elements in this library never name a peer. A queue does not know
what is downstream of it; it asks its output gate for something that provides
the passive-sink interface and gets a reference with a delay attached. So
rewiring a network is rewiring, full stop — no string in a configuration file
has to be found and updated to match, because there is no string.

The cost is that a lookup can fail at build time rather than at parse time, and
`resolve_interface` makes that failure loud: a mandatory lookup that finds
nothing is an error naming the gate and the interface, raised while the network
is being built rather than when the first packet arrives and finds nowhere to
go.
