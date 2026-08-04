# Filtering packets out

A filter passes on the packets its predicate accepts and drops the rest where
they stand. It is the classifier's simpler cousin: one output instead of
several, and a packet that fails the test goes nowhere rather than elsewhere.

The predicate reads the value the source wrote, so which packets survive is a
property of the packets and not of the wiring.

## The network

```pred-ref
<<definition(file("../steps/classify.jl"), "_build_filter_network")>>
```

## Run it

The source writes one of `classes` values on each packet and the filter keeps
only `keep`, so about one packet in `classes` reaches the sink. Change `keep`
and a different quarter of the traffic gets through; raise `classes` and less
of it does.

A filter can also refuse a packet instead of dropping it — the source then has
to hold on to it — which is what the elements call back pressure. This step
drops, because a source that cannot be refused is the simpler thing to watch.

```pred-ref
<<realize(file("filtering/Filter.json"))>>
```
