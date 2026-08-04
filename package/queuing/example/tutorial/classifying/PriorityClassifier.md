# Classifying by what the outputs will take

The other kind of classifier does not look at the packet at all. A *priority
classifier* tries its outputs in order and sends each packet out of the first
one that will take it, so a full output is passed over and the next gets the
overflow.

That makes the ordering of the outputs a policy: whatever is wired first is
preferred, and the rest are there for what does not fit.

## The network

Two queues behind the classifier, the first one small. A scheduler and a server
downstream keep them draining, so the small queue is repeatedly filled and
emptied rather than simply full:

```pred-ref
<<definition(file("../steps/classify.jl"), "_build_priority_chain_network")>>
```

## Run it

Watch `first_capacity`. A larger first queue takes a larger share of the
traffic, because the classifier only reaches for the second when the first
refuses. Set it high enough and the second queue is never used at all — the
overflow path is there for the traffic the preferred path cannot hold, and for
nothing else.

```pred-ref
<<realize(file("classifying/PriorityClassifier.json"))>>
```
