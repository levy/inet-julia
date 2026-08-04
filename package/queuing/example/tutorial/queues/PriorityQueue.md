# The priority queue as one element

The scheduling step assembled a priority queue out of a classifier, two queues
and a scheduler. This step uses the element that *is* that assembly: one call
builds the submodules and wires them, and the chain around it sees a single
queue.

Look at the diagram: the submodules are still there, with their own names
inside the compound. A compound module is not a black box — it is a name for a
piece of network, and everything in it is a module like any other.

## The network

```pred-ref
<<definition(file("../steps/serve.jl"), "_build_priority_queue_network")>>
```

## Run it

`priorities` is how many levels the queue has and `level_capacity` how much
each holds. A packet goes to the first level that will take it and the
scheduler always drains the first level first, so the second is used only for
what arrives while the first is full — with the server keeping up, that is a
small share of the traffic, and it grows as you lower `level_capacity` or
raise `arrival_rate`.

The levels *refuse* when full rather than dropping, which is what makes the
overflow an overflow: a level that dropped would accept the packet first, and
the classifier would never reach the second level at all.

```pred-ref
<<realize(file("queues/PriorityQueue.json"))>>
```
