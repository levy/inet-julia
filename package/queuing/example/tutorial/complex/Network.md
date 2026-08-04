# Putting it together

Two sources feeding one priority queue through a multiplexer, drained by a
server whose output is filtered on the way to the sink.

Nothing here is new. Every element appeared in an earlier step and every one is
doing exactly what it did there — which is the point of the step: the elements
compose, and a bigger network is the same parts wired together.

Notice what did *not* have to happen. The multiplexer was not told it is
feeding a compound. The compound was not told a filter is downstream. The
server takes what the scheduler inside the queue hands it and does not know
there were ever two sources.

## The network

```pred-ref
<<definition(file("../steps/network.jl"), "_build_complex_network")>>
```

## Run it

Two sources at `arrival_rate` each against a server at one over
`processing_time`: raise either and the queue levels fill, and the drops start
at the level that overflows first. `pass_rate` then throws away a share of what
survived all that — the sink's count is the product of every stage before it.

The diagram is worth a look here. The compound's submodules are in it under
their own names, so what you see is the whole network, not a picture of it.

```pred-ref
<<realize(file("complex/Network.json"))>>
```
