# Making more packets

Two ways of ending up with more packets than you started with, side by side.

A **cloner** fans a stream out: every output gets its own copy of every packet.
A **duplicator** thickens a stream in place: one output, and the packets its
predicate picks go down it twice. The first is how one stream feeds two
independent chains; the second is how a model produces the retransmissions and
echoes a receiver has to cope with.

Copies share their content and get their own tags, which is what lets each
branch label its copies differently without disturbing the others.

## The network

The first branch is thickened again, so the two sinks' counts can be compared:

```pred-ref
<<definition(file("../steps/marking.jl"), "_build_cloner_network")>>
```

## Run it

The second sink counts exactly what the source produced — one copy each. The
first counts that plus one for every `duplicate_every`-th packet, so at 2 it
sees half again as many. Change `duplicate_every` and only the first count
moves.

There is one rule a cloner follows that is worth knowing: it refuses a packet
unless *every* output will take it. Handing out three copies and then
discovering the fourth output is full would leave the stream half-cloned, and
nothing downstream could make sense of that.

```pred-ref
<<realize(file("marking/Cloner.json"))>>
```
