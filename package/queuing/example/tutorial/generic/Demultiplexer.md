# Sharing one source between several collectors

The multiplexer's mirror, working in the other direction: a multiplexer joins
several *pushing* chains, a demultiplexer lets several *pulling* ones share one
provider.

Whichever sink asks first gets the packet, so where a packet goes says
something about the collectors' timing and nothing about the packet. That is
exactly what separates it from a classifier, which reads the packet and
chooses.

## The network

```pred-ref
<<definition(file("../steps/plumbing.jl"), "_build_demultiplexer_network")>>
```

## Run it

Both sinks collect on the same interval here, so they split the traffic between
them. The total is set by how often the sinks ask — the source produces a packet
only when one of them wants it, which is what "passive" means.

```pred-ref
<<realize(file("generic/Demultiplexer.json"))>>
```
