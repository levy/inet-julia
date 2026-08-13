# The M/M/1/K chain

Four elements in a row: a source that produces packets, a queue that holds the
ones that cannot be served yet, a server that serves them one at a time, and a
sink that counts what comes out. It is the smallest arrangement in which a
queue is doing anything, and it is the arrangement most of INET's queueing
tutorial is built out of.

Arrivals and service times are exponential here, so this is the textbook
M/M/1/K queue: with a capacity, what does not fit is dropped; without one
(capacity `0`) the queue is unbounded and the model is M/M/1.

## The network

This is the model's own source, read from the file the engine loads — not a
copy of it. The elements are connected in construction order, and those
connections are what the engine reads:

```pred-ref
<<definition(file("../../../queuing/main/QueuingModel.jl"), "_build_queuing_network")>>
```

Four `add_module!` calls and three `connect_gates!` calls. There is no network
description language here and nothing generated from one: the function above
*is* the network, and `model_topology` derives the diagram from the same
connections rather than from a second description that could disagree with it.

## Run it

Press **Run**. The form's fields are the model's declared parameter space, so a
model that grows a degree of freedom grows a form field for free — nobody
writes a dialog. The chart fills from the queue's own `queueLength` series
while the run goes.

```pred-ref
<<realize(file("pages/Mm1kChain.json"))>>
```

Now raise `arrival_rate` towards `service_rate` and press Run again. The queue
grows: at `5` against `10` the server is idle half the time and the queue is
almost always short, and by `9` against `10` it spends most of the run near its
capacity. Past `service_rate` the queue is unstable, and the capacity is the
only thing keeping the run bounded — which is what `packet_capacity` is for.

## Why the numbers are the right numbers

The theory for M/M/1 says that at utilisation ρ the mean number waiting is
ρ²/(1−ρ) and, by Little's law, the mean wait is that number divided by the
arrival rate. Those are not decorations on this page: `phase2_queue_server.jl`
runs this same chain at ρ = 0.5 for 5000 simulated seconds and asserts that the
measured `queueLength:timeavg` lands near 0.5, that the measured
`queueingTime:mean` lands near 0.1 s, and that Little's law relates the two
measured numbers to within 5%.

So the queue is not merely plausible. It is checked against the closed form on
every run of the suite, which is the only reason a page like this one is
allowed to make the claim at all.
