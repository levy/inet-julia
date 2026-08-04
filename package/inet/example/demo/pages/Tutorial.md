# The whole tutorial

INET ships a queueing tutorial: twenty-odd steps that build a network one
element at a time, each step the previous one with a single element added or
swapped. It is migrated here in full, and it is a deliverable in its own right
rather than an appendix to this catalog.

What makes it worth pointing at from here is that **it is made of the same
material this page is made of**. Every step is a markdown page with the model's
own source spliced in and the simulation itself sitting in the prose; the
navigator on the left is derived from the tutorial's `index.md` in exactly the
way this catalog's is derived from its own; and the shell showing you this
sentence is the shell that shows a step. This catalog is not a demo *of* the
tutorial's machinery — it is another thing built out of it.

## A step, here

This is a tutorial step file, embedded on this page. Not a copy of one — the
same file, named by path, that the tutorial's own Queue step embeds:

```pred-ref
<<realize(file("../../../queuing/example/tutorial/queues/Queue.json"))>>
```

A step file names a model, some parameter values and a run limit, and that is
the entire description of a runnable card. Nothing about it is tutorial-specific
— which is why this page could pick it up and use it without asking anyone.

## Opening the tutorial itself

The tutorial is its own catalog, with its own root file and its own index, so
it opens on its own:

```
julia --project=. package/queuing/example/run.jl
```

or from a REPL that already has the packages loaded:

```
using InetQueuingExample
load_tutorial()          # the shell, headless
```

Its steps are grouped the way the index groups them — sources and sinks,
queues, classifying, scheduling, filtering, serving, generic elements,
labelling, and one complex example that puts them together. Start at the first
one; each is the previous one plus a single change, and each says which change.

## Why it is not listed step by step here

The obvious thing would be to list all twenty-odd steps in the navigator on the
left, and that was considered. Two reasons not to.

The first is editorial: a catalog that lists everything is not a catalog. The
tutorial is already ordered, already grouped and already has an index that
reads better than a flattened list of its steps would.

The second is mechanical and worth knowing if you write pages here. **Marker
paths resolve against the catalog's own base directory**, not against the file
the marker sits in. That is deliberate — it gives every target one canonical
name, and therefore one interned document — but it means a page written for the
tutorial's base directory cannot simply be opened from this catalog's: its
`file("queues/Queue.json")` would be looked for under this directory and not
found. Step *files* travel fine, as the card above demonstrates, because a step
file names a model rather than a path. Step *pages* do not.
