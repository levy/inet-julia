# The same numbers as INET

A port that claims to be faithful should be checkable, and the only way to make
it checkable is to emit the same signals under the same names in the same
places, so that a run here and a run of INET can be diffed rather than
compared by eye.

That is what this model does. Its result files use INET's own signal names and
INET's own module paths, and the diffing is a harness in the test suite rather
than a slide in a presentation.

## The signals

Every node emits the same set at each layer:

```pred-ref
<<definition(file("../../../linklayer/main/t1s/T1sModel.jl"), "_PLCA_SIGNALS")>>
```

Sixteen at the PLCA layer, five at the MAC, six at the PHY — twenty-seven
signals per node. They are held as short symbols internally, and the name
registered with the recorder appends `:vector`, which is how INET spells a
recorded time series. The module path is INET's too:

```pred-ref
<<definition(file("../../../linklayer/main/t1s/T1sModel.jl"), "_inet_node_path")>>
```

`MultidropNetwork.controller` and `MultidropNetwork.node[i]` are not names
chosen for this port. They are the names INET's `MultidropNetwork.ned` gives
those modules, and matching them is what lets a comparison key on module path
and signal name together instead of on a hand-maintained mapping table.

## What a comparison decides

Diffing two result files is not "are these arrays equal". Some signals must
match sample for sample; others are driven by a random stream that the two
implementations consume in a different order, and demanding equality of those
would be demanding the wrong thing. So the tolerances are a table:

```pred-ref
<<definition(file("../../../linklayer/test/T1sVectorComparison.jl"), "T1S_VECTOR_RULES")>>
```

The PLCA cycle structure is `:exact` — `curID`, `cycleLength`, `toLength` and
the state transitions are fixed by the arbitration, so an equivalent
implementation reproduces them exactly, and a single differing sample is a real
disagreement worth chasing. The packet-arrival signals get
`:count_within(2)`, because they are RNG-driven.

That table is the interesting artifact on this page. It is a written-down claim
about which parts of this protocol are deterministic, and it is the sort of
thing that usually lives in somebody's head.

## The honest part

The comparison harness (`compare_t1s_vectors`, above it in the same file)
works. What is missing is the other side of it: **the INET reference files are
not in this repository.** Producing them is a manual step against a real
OMNeT++ and INET install — build the model, run the scenario, keep the `.vec` —
and nobody has committed the output.

So the claim this page makes is narrower than "the numbers match", and it is
worth stating in exactly the words it deserves: the model emits what INET emits,
under the names INET uses, and the machinery to diff a run against a reference
exists and is tested. Whether every series agrees is a question this repository
can *ask* precisely, and cannot yet answer for you.

What is already checked, every run of the suite, is the part that needs no
reference at all: `notraffic` at five nodes has an analytically derived cycle
length — a 2 µs beacon, 1 ns of syncing, and five 3.2 µs transmit opportunities,
so 18.001 µs — and `phase2_stats_core.jl` pins the emitted `cycleLength` to it.
A cycle that drifted by a nanosecond would fail there.
