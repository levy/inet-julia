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
each holds. Packets fill the first level until it is full, overflow into the
second, and are served highest level first — the classifier and the scheduler
inside the element doing exactly what you wired by hand two steps ago.

```pred-ref
<<realize(file("queues/PriorityQueue.json"))>>
```
