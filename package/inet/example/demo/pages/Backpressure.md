# Backpressure is a conversation

A gate between two queueing elements has two questions to settle: who starts
the exchange, and which way the packet goes. That is four roles — a source can
be active (it pushes) or passive (it is pulled from), and a sink likewise — and
every element in this library declares which ones it plays.

The interesting consequence is what happens when the downstream end says *no*.
A refusal is a first-class answer, not a dropped packet, and a peer that asked
with a packet in hand has to keep holding it.

## The chain

Source, queue, server, filter, sink — with the filter set either to drop what
it will not pass on, or to refuse it:

```pred-ref
<<definition(file("../../../queuing/example/steps/serve.jl"), "_build_backpressure_network")>>
```

Two lines carry the whole demonstration. `predicate` decides which packets the
filter accepts, and `backpressure` decides what it does with the rest.

## Run it

```pred-ref
<<realize(file("pages/Backpressure.json"))>>
```

`pass_rate` is `0.0`, so the filter accepts nothing at all. With
`backpressure = true` the filter refuses, and the refusal propagates: the
server will not start serving a packet it could not then deliver, so it stalls,
and the queue behind it stops draining. The source does not feel any of this —
it is an active source on a timer, and it keeps producing — so the queue climbs
for the whole run. Over 100 seconds it produces 991 packets, the sink receives
none, and **nothing is dropped anywhere**: every packet the chain could not
deliver is still in the queue. The queue here has no capacity set, so its
average length over the run is about 483 and still rising at the end.

Now set `backpressure` to `false` and Run again. The chain runs freely: the
server serves, the filter takes each packet and discards it, and the queue
stays essentially empty — a mean length of 0.007 against 483. Same arrival
rate, same service time, same predicate, same 991 packets produced and the same
none delivered. What differs is where the loss went and whether anything
upstream noticed.

## Why the distinction earns its keep

A dropping filter is easy to model and easy to mislead yourself with. The chain
upstream of it runs at full tilt, every counter looks healthy, the queue reads
0.007, and the loss only shows up if you go looking for the one counter that
records it.

A refusing filter makes the loss structural: it shows up as a queue that fills
and a server that idles, which is what a real link under congestion actually
looks like. Note which module did *not* change its behaviour, though. Back
pressure is only felt by a peer that asks *with a packet in hand*, and an
active source pushing on a timer never asks — so it produced its 991 packets
either way. Which of the four roles an element plays decides whether it can
experience congestion at all, which is exactly why the roles are declared
rather than assumed.
