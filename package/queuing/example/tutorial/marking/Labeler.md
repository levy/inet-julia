# Writing on a packet

The classifying step had a source that labelled its own packets. That is
convenient and rarely true: traffic usually comes from somewhere that knows
nothing about how you intend to sort it.

A labeler writes the value on the way past. It writes the *same* tag a source
would have, so nothing downstream can tell the difference — a classifier or a
comparator reads a labeller's work exactly as it reads a source's.

## The network

The source says nothing about its packets; the labeler writes, and the
classifier sorts by what it wrote:

```pred-ref
<<definition(file("../steps/marking.jl"), "_build_labeler_network")>>
```

## Run it

With `labels` at 2 the traffic splits about evenly between the sinks. Raise it
and the last output takes everything the earlier predicates did not — the same
default that keeps a classifier from ever having nowhere to put a packet.

The interesting thing to notice is what is *not* here. There is no agreement
between the labeler and the classifier beyond the value itself: no shared
enumeration, no registration, no type. One writes a number and the other reads
it.

```pred-ref
<<realize(file("marking/Labeler.json"))>>
```
