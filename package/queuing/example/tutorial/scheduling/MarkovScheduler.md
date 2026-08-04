# Sharing in bursts

Weighted round robin hands out turns evenly: with weights `3` and `1` the
pattern is three, one, three, one, forever. Real traffic rarely arrives that
tidily — it clumps — and a Markov policy is how you get the same long-run
shares in a clumped order.

The classifier is in one of two states, sends each packet out of the output its
state names, and then moves on with a probability. Make it likely to stay and
you get long runs one way; make it unlikely and you are back to alternating.

## The network

Same network, same elements, a different function in the fork:

```pred-ref
<<definition(file("../steps/classify.jl"), "_shared_chain_classifier")>>
```

## Run it

`stickiness` is how often the walk stays where it is. At `0.9` the two paths
still get about half each over the whole run — the chain is symmetric — but
they get it in runs of ten or so rather than one at a time. Drop it to `0.5`
and the classifier is choosing at random each time; raise it towards `1.0` and
the traffic arrives in ever longer blocks.

The shares are the same, the burstiness is not, and downstream that difference
is what fills a queue: the same average load arriving in clumps needs more room
than the same load arriving evenly.

```pred-ref
<<realize(file("scheduling/MarkovScheduler.json"))>>
```
