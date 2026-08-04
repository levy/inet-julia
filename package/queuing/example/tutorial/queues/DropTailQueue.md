# A queue that drops what does not fit

The previous step's queue had room for everything that arrived. Give it a
capacity and send packets faster than they can be served, and the queue has to
decide what to do with a packet that arrives full.

This one drops the arriving packet — the *tail* of the queue — and lets the
packets already waiting through. That is the simplest policy there is, and the
one every more interesting policy is measured against.

## The network

It is the same chain as the previous step; what makes it drop is a capacity
with a dropper, which the builder attaches only when a capacity is set:

```pred-ref
<<definition(file("../../main/QueuingModel.jl"), "_build_queuing_network")>>
```

## Run it

Arrivals at 12/s against a server that manages 10/s cannot all be served, so the
queue fills and the drops begin. Watch `packet_capacity`: a bigger queue drops
fewer packets but makes the ones it keeps wait longer — the trade every queue
makes, and the reason the later steps care about *which* packet is dropped.

```pred-ref
<<realize(file("queues/DropTailQueue.json"))>>
```
