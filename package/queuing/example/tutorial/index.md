# The queuing tutorial

This tutorial builds up a queueing network one element at a time. Every step is
a page like this one: prose that explains an element, the model's own source
next to it, and the simulation itself — configurable and runnable without
leaving the page.

The models are Julia. Where INET's tutorial shows a NED network and an INI
config, this one shows the code that builds the network and the values the step
sets, because in this port the Julia form *is* the model.

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

## Classifying

- [Classifying by what a packet says](classifying/ContentBasedClassifier.md) —
  a value on each packet, and a fork that reads it.

## Scheduling

- [A priority queue, assembled from parts](scheduling/PriorityScheduler.md) —
  a classifier, two queues and a scheduler, and what "priority" turns out to be.

## Filtering

- [Filtering packets out](filtering/Filter.md) — passing on some packets and
  dropping the rest.
