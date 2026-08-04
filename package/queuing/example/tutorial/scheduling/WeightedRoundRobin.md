# Sharing by weight

A priority policy is all-or-nothing: the preferred path gets everything it can
hold and the other gets the leftovers. Often what you want instead is a
*share* — three packets this way for every one that way — and that is weighted
round robin.

The classifier gives each output a run of its weight before moving on, and the
scheduler drains the queues by the same rule. Neither consults the packet, and
neither is a new kind of element: both are the classifier and the scheduler you
already know, given a different function.

## The network

The policy is a parameter, so the same network runs all three. This is what
picks the fork:

```pred-ref
<<definition(file("../steps/classify.jl"), "_shared_chain_classifier")>>
```

## Run it

With `policy` at `round_robin` and weights `3` and `1`, three quarters of the
packets take the first path. Change the weights and the split follows them
immediately — that is the whole appeal of the policy.

Switch `policy` to `priority` and the split stops being a share at all: the
first queue takes everything it can hold. Switch it to `markov` and the shares
come back, but arriving in bursts rather than in turn.

There is one asymmetry worth knowing. A classifier is *told* which output to
use, so a full one loses its turn. A scheduler is *asked* whether it can pull
at all, so an empty input has to forfeit the rest of its run rather than stall
the cycle behind it — otherwise one idle queue would stop the whole chain.

```pred-ref
<<realize(file("scheduling/WeightedRoundRobin.json"))>>
```
