# INET, native in Julia

The protocol models are ordinary Julia — a header declaration that is also its
own bit-exact codec, a queueing element you can read top to bottom, a state
machine that is a document before it is code. They run on a deterministic
discrete-event kernel, and the model, the run it produces and the results it
records are **one live document**.

That last part is the claim worth checking, and this catalog is built so you
can check it. Every page here is prose with things spliced into it: the model's
own source, read out of the file the engine reads — never a quotation that can
drift; a simulation you can configure and run without leaving the page; a chart
that fills while it runs. None of it is a screenshot, and none of it was
generated for the demo.

## How to read this

Pick a page from the list on the left; it stays there, so you can wander.

Each page opens with prose saying what the feature is and why it matters, then
shows the thing itself, then tells you one concrete thing to try — press Run,
change this parameter, compare those two numbers. The pages are independent:
read them in any order.

If you leave a page half-run and come back, it is still half-run. Pages are
loaded once and kept, which is the document model doing its job rather than a
feature anyone built for the tour.

## The packet, taken apart

- [A packet is chunks](pages/PacketIsChunks.md) — an immutable, structurally
  shared body under a mutable envelope, and what a broadcast actually copies.
- [Headers declare their own bytes](pages/Headers.md) — one declaration, a
  struct and its bit-exact codec, and a guard against reading the wrong one.
- [The packet, drawn the way the standard draws it](pages/PacketDiagram.md) —
  the RFC bit grid, projected from the packet rather than drawn beside it.
- [Knowing what you know](pages/Quality.md) — three monotone bits, and a `peek`
  that refuses damaged data until you ask for it by name.
- [Reassembly without ceremony](pages/Reassembly.md) — straddling pops, sparse
  segments, and overlap policies as explicit values.

## One protocol, one page

A page per wire format, and no line of any of them written by hand. The
declaration is quoted from the file that declares it; the call that builds an
instance, the byte a field update moves, the reflected fields and the bit grid
are all computed from the type. A page cannot disagree with the code, because
there is nothing on it that the code did not say.

- [IPv4 — RFC 791](pages/header/Ipv4Header.md) — sub-byte widths, a check, a
  derive, and an option list that runs to the end of the header.

## Queuing, element by element

- [The M/M/1/K chain](pages/Mm1kChain.md) — four elements in a row, and a
  queue whose measured behaviour is checked against the closed form.
- [Backpressure is a conversation](pages/Backpressure.md) — four roles at every
  gate, and a refusal that is an answer rather than a dropped packet.
- [The whole tutorial](pages/Tutorial.md) — twenty-odd steps, built out of the
  same material this page is.

## 10BASE-T1S, faithfully

- [A bus that takes turns](pages/Plca.md) — PLCA arbitration on a real
  junction-chain bus, and a cycle length you can predict to the nanosecond.
- [State machines, generated](pages/Fsm.md) — the protocol's machines are
  documents, and the running code is generated from them.
- [The same numbers as INET](pages/Statistics.md) — INET's own signal names and
  module paths, and a diffing harness with its tolerances written down.

## Finding the module that answers

- [Interface lookup](pages/InterfaceLookup.md) — a module finds its protocol
  peer by walking real connections, instead of by a string path.
