# A passive source and an active sink

The same two elements as the previous step, with the initiative the other way
round: the sink decides when it wants a packet, and the source hands one over
on request.

Nothing about the packets changes — what changes is who drives. Every element
in this library plays one of these two roles at each of its gates, and that is
what lets a queue sit between a pushing source and a pulling server without
either of them knowing about the other.

## The network

```pred-ref
<<definition(file("../steps/sources.jl"), "_build_pull_network")>>
```

## Run it

The sink collects every `collection_interval` seconds, so the count is set by
the *consumer* here, not the producer. Compare it with the previous step: same
elements, same packets, and the number that decides how many there are has
moved to the other end of the connection.

```pred-ref
<<realize(file("sources/PassiveSourceActiveSink.json"))>>
```
