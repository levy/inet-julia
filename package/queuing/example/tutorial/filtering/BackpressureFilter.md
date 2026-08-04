# Refusing instead of dropping

The filtering step dropped what it would not pass on. A filter can instead
*refuse* it — and refusing is not losing: the packet stays where it was, and
whoever was holding it has to deal with that.

Back pressure is only felt by a peer that asks with a packet in hand. A server
does: it will not start serving a packet it could not then deliver. So a
refusing filter stops the server, and the queue behind it fills up instead.

## The network

```pred-ref
<<definition(file("../steps/serve.jl"), "_build_backpressure_network")>>
```

## Run it

With `backpressure` on and `pass_rate` at zero, nothing gets through: the
server never starts, the queue holds everything the source made, and the filter
has dropped not one packet. Turn `backpressure` off and the same chain runs dry
— the server serves, the filter drops, and the queue is empty at the end.

Same elements, same wiring, same numbers going in. The difference is entirely
in what "no" means.

```pred-ref
<<realize(file("filtering/BackpressureFilter.json"))>>
```
