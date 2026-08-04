# Holding a packet for a while

A delayer takes a packet, keeps it for a while and then passes it on. It
decides nothing and drops nothing; the only thing it changes is *when* a packet
arrives.

## The network

```pred-ref
<<definition(file("../steps/plumbing.jl"), "_build_delayer_network")>>
```

## Run it

With a fixed `delay` the packets come out in the order they went in, just
later, and the number that arrive is the number that were produced minus the
few still in flight when the run ends.

Turn `random_delay` on and each packet is held for its own draw, so packets can
overtake one another. That is what a path whose delay varies does to a stream —
and the reason a protocol that cares about order cannot simply assume one.

```pred-ref
<<realize(file("generic/Delayer.json"))>>
```
