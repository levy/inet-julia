# The server, and what it costs to serve

A server takes one packet at a time and holds it for `processing_time` before
passing it on. It is the element that makes a queue necessary: everything
waiting is waiting for the server.

The chain is the one from the queue steps — what changes here is which number
you watch.

## The network

```pred-ref
<<definition(file("../../main/QueuingModel.jl"), "_build_queuing_network")>>
```

## Run it

`service_rate` is one over the processing time: at 10 packets per second the
server can carry an arrival rate up to 10, and no more. Push `arrival_rate`
towards it and the queue grows without bound; push it past and the queue would
grow forever, which is why a capacity is not optional in that regime.

The interesting number is the ratio of the two. At half the service rate the
queue is almost always short; at nine tenths it is long and the waiting
dominates. Nothing about the elements changes between those two runs — only one
parameter does.

```pred-ref
<<realize(file("serving/Server.json"))>>
```
