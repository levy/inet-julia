# An active source and a passive sink

The smallest queueing network there is: a source that decides when a packet
appears, pushing it straight into a sink that takes whatever arrives. Nothing
waits and nothing is served, so what a run shows is the production process
itself.

The source is *active* — it schedules its own next packet — and the sink is
*passive*, taking what it is given. Every network in the later steps is this
pair with something in between.

## The network

```pred-ref
<<definition(file("../steps/sources.jl"), "_build_source_sink_network")>>
```

## Run it

With `random_intervals` off, packets appear like clockwork: a run of
`time_limit` seconds at one packet every `production_interval` produces exactly
as many as you would count on your fingers.

Turn `random_intervals` on and the source draws each interval from an
exponential distribution with the same mean. The count comes out near the same
number but never on it — this is the Poisson arrival process every later step's
traffic is made of, and the reason those steps talk about averages.

```pred-ref
<<realize(file("sources/ActiveSourcePassiveSink.json"))>>
```
