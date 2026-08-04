# The queuing tutorial

This tutorial builds up a queueing network one element at a time. Every step is
a page like this one: prose that explains an element, the model's own source
next to it, and the simulation itself — configurable and runnable without
leaving the page.

## How to read a step

Each step's page has the same three parts.

The **prose** says what the element does and what to watch for. The **network**
is the model's own source, embedded from the file it lives in — not a quotation
of it, so it cannot drift from what actually runs. The **simulation** is live:
its parameters are the model's declared degrees of freedom, and editing one and
pressing Run runs the edited model.

The models are Julia. Where INET's tutorial shows a NED network and an INI
config, this one shows the code that builds the network and the values the step
sets, because in this port the Julia form *is* the model. Nothing is generated
from anything: the diagram, the parameter form and the run all read the same
network the engine reads.

Steps are meant to be read in order — each one is the previous one with a
single element added or swapped — but every page stands on its own, so skipping
ahead costs you only the sentence that says "as in the previous step".

## Sources and sinks

- [An active source and a passive sink](sources/ActiveSourcePassiveSink.md) —
  the smallest network there is, and the arrival process every later step uses.
- [A passive source and an active sink](sources/PassiveSourceActiveSink.md) —
  the same two elements with the initiative the other way round.

## Queues

- [A single queue](queues/Queue.md) — packets arrive, wait their turn, are
  served one at a time, and are counted.
- [A queue that drops what does not fit](queues/DropTailQueue.md) — what a
  queue does when more arrives than it can hold.
- [The priority queue as one element](queues/PriorityQueue.md) — a compound
  module, and what is still visible inside one.

## Classifying

- [Classifying by what a packet says](classifying/ContentBasedClassifier.md) —
  a value on each packet, and a fork that reads it.
- [Classifying by what the outputs will take](classifying/PriorityClassifier.md)
  — the other kind, which does not look at the packet at all.

## Scheduling

- [A priority queue, assembled from parts](scheduling/PriorityScheduler.md) —
  a classifier, two queues and a scheduler, and what "priority" turns out to be.
- [Sharing by weight](scheduling/WeightedRoundRobin.md) — when you want a
  share rather than a preference.
- [Sharing in bursts](scheduling/MarkovScheduler.md) — the same shares,
  arriving clumped.

## Filtering

- [Filtering packets out](filtering/Filter.md) — passing on some packets and
  dropping the rest.
- [Refusing instead of dropping](filtering/BackpressureFilter.md) — what back
  pressure is, and who feels it.
- [Naming a policy instead of writing it](filtering/NamedPolicy.md) — how a
  choice lives in data rather than in code.

## Serving

- [The server, and what it costs to serve](serving/Server.md) — the element
  that makes a queue necessary.

## Generic elements

- [Holding a packet for a while](generic/Delayer.md) — the element that
  changes only *when* a packet arrives.
- [Joining several chains into one](generic/Multiplexer.md) — feeding one
  chain from several places.
- [Sharing one source between several collectors](generic/Demultiplexer.md) —
  the same idea in the pull direction.

## Complex examples

- [Putting it together](complex/Network.md) — every element so far in one
  network, and what none of them had to be told.
