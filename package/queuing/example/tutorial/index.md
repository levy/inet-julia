# The queuing tutorial

This tutorial builds up a queueing network one element at a time. Every step is
a page like this one: prose that explains an element, the model's own source
next to it, and the simulation itself — configurable and runnable without
leaving the page.

The models are Julia. Where INET's tutorial shows a NED network and an INI
config, this one shows the code that builds the network and the values the step
sets, because in this port the Julia form *is* the model.

## Queues

- [A single queue](queues/Queue.md) — packets arrive, wait their turn, are
  served one at a time, and are counted.
