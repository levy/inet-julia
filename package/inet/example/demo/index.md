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

## Queuing, element by element

- [The M/M/1/K chain](pages/Mm1kChain.md) — four elements in a row, and a
  queue whose measured behaviour is checked against the closed form.
