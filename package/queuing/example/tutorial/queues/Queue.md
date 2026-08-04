# A single queue

The simplest interesting queueing network is a chain of four elements: a source
that produces packets, a queue that holds the ones that cannot be served yet, a
server that serves them one at a time, and a sink that counts what comes out.

Arrivals and service times are exponential here, so this is the textbook
M/M/1/K queue — with a capacity, what does not fit is dropped; without one
(capacity `0`) the queue is unbounded and the model is M/M/1.

## The network

This is the model's own source, not a copy of it — the elements are connected
in construction order, and the connections are what the engine reads:

```pred-ref
<<definition(file("../../main/QueuingModel.jl"), "_build_queuing_network")>>
```

## Run it

Press **Run**. The parameters are the model's declared degrees of freedom, so
editing one and pressing Run again re-runs the edited model.

Raising `arrival_rate` towards `service_rate` makes the queue grow; past it,
the queue is unstable and a capacity is what keeps the run bounded.

```pred-ref
<<realize(file("queues/Queue.json"))>>
```
