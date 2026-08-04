# A priority queue, assembled from parts

A classifier fans packets into a queue each, a scheduler drains them in order,
and one server takes them away. That is a priority queue — and none of the four
elements was told about priorities.

The classifier prefers the first queue while it will take packets, so the small
one fills first. The scheduler always takes from the first input that has
anything, so the small queue is emptied before the second is touched. Priority
is what those two orderings add up to.

## The network

```pred-ref
<<definition(file("../steps/classify.jl"), "_build_priority_chain_network")>>
```

## Run it

Packets arrive faster than the server can serve them, so both queues are in use.
Raise `first_capacity` and more of the traffic goes through the preferred queue;
lower it and the overflow queue does more of the work. The server sees no
difference at all — it takes whatever the scheduler hands it.

```pred-ref
<<realize(file("scheduling/PriorityScheduler.json"))>>
```
