# Classifying by what a packet says

Until now every packet was the same as every other, and the only thing a step
could do with one was count it. This one gives each packet a value and forks the
chain by it: a *content-based classifier* asks a predicate per output and sends
the packet out of the first one that says yes.

The value is written by the source and read back by the classifier — nothing in
between looks at it, and nothing downstream of the fork sees anything but its
own share.

## The network

```pred-ref
<<definition(file("../steps/classify.jl"), "_build_content_classifier_network")>>
```

## Run it

With `classes` set to 2 the source draws 1 or 2 for each packet and the two
sinks get roughly half each. Raise `classes` and the last output takes
everything the earlier predicates did not — the default that keeps a classifier
from ever having nowhere to put a packet.

```pred-ref
<<realize(file("classifying/ContentBasedClassifier.json"))>>
```
