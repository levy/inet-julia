# A bus that takes turns

10BASE-T1S is multidrop Ethernet: one pair of wires, every node attached to the
same segment, no switch anywhere. That means collisions, and CSMA/CD on a
shared automotive bus gives latencies nobody can bound.

PLCA — Physical Layer Collision Avoidance, IEEE 802.3cg-2019 §148 — removes
them by making the bus take turns. A coordinator sends a BEACON to start a
cycle. Every node holds an ID, and the cycle walks the IDs in order, giving each
one a transmit opportunity in turn. A node with nothing to send yields its slot
immediately, so an idle bus runs its cycles quickly; a node with a packet uses
its slot and nobody else is talking, so there is no collision to detect. The
result is bounded, and computable in advance.

## The model, running

This is a real junction-chain bus: a coordinator and *n−1* followers hanging off
a chain of junctions by their own stubs, with the segment and stub propagation
delays the topology actually has. Every node runs its own PHY, PLCA and MAC.

```pred-ref
<<realize(file("pages/Plca.json"))>>
```

Press **Run**, then read the chart against this arithmetic.

With no traffic at five nodes, a cycle is a 2 µs beacon, 1 ns of syncing, and
five 3.2 µs transmit opportunities that nobody uses — so **18.001 µs**, and
100 µs of simulated time holds five of them. That number is not a measurement
someone wrote down afterwards: it is derived from the standard's timings, it is
what the chart shows, and `phase2_stats_core.jl` pins the emitted `cycleLength`
to it on every run of the suite.

Now raise `n_nodes` and Run again. Each extra node is one more transmit
opportunity, so each adds 3.2 µs: eight nodes give 27.601 µs, three give
11.601 µs. The bus is slower with more nodes on it, by exactly the amount the
standard says and not a nanosecond more — which is the property that makes PLCA
usable in a car.

Every node measures the cycle for itself, and they all agree: arbitration is a
property of the bus, so `MultidropNetwork.controller` and each
`MultidropNetwork.node[i]` record the same 18.001 µs, offset by the propagation
delay to where each one sits.

## What the `scenario` parameter is, honestly

`scenario` offers `notraffic`, `bestcase` and `worstcase`. Only `notraffic` is
finished. The other two are placeholders: `_sources_for_scenario` currently
gives every follower the same fixed 10 µs cadence for both, and the source
comment says the real per-node offsets are a follow-up. So switching between
`bestcase` and `worstcase` today changes nothing, and this page will not tell
you it does.

The cycle arithmetic above is not affected — it is the empty-bus case, and it is
the case that is pinned.

## Where the numbers go

The run you just did recorded 135 result vectors: twenty-seven signals for each
of the five nodes, under INET's own names and INET's own module paths. What
that is for, and what can and cannot yet be checked against a real INET run, is
[the next page](Statistics.md).
