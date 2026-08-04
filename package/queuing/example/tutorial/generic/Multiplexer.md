# Joining several chains into one

A multiplexer forwards whatever arrives on any of its inputs to its one output.
It holds nothing and decides nothing — it is how a chain gets fed from more
than one place without the chain knowing there is more than one.

## The network

```pred-ref
<<definition(file("../steps/plumbing.jl"), "_build_multiplexer_network")>>
```

## Run it

Each source produces at `arrival_rate`, so the sink sees about `sources` times
as many packets as any one of them sent. Add sources and the combined stream
grows; the sink's own code does not change, because as far as it is concerned
there was only ever one stream.

Note that each source is given its own seed. Without that they would all draw
the same intervals and produce the same stream, which is a mistake worth making
once and never again.

```pred-ref
<<realize(file("generic/Multiplexer.json"))>>
```
