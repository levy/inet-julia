# Reassembly without ceremony

Two containers cover most of what a receiver does with fragments. A
`ChunkQueue` is a FIFO you pop *lengths* out of. A `ChunkBuffer` is a sparse
map from offset to content, which is what reassembly and reordering both are.
Neither needs a protocol to sort anything.

## Popping across a boundary

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "straddling_pop")>>
```

Two four-byte chunks go in; six bytes come out. The pop crosses the boundary
between them and normalises on the way: what comes back is
`[0x01, 0x01, 0x01, 0x01, 0x02, 0x02]`, and two bytes are left in the queue.

The caller asked for a *length*, not for a chunk. Where one chunk ends and the
next begins is the queue's business — which is exactly right, because a link
layer that has buffered six bytes does not care that they arrived as two writes.

## Filling in the gaps

A `ChunkBuffer` takes segments at their offsets, in any order, and can say at
any moment what it is still missing:

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "reassemble_out_of_order")>>
```

Thirty bytes of message arriving last, first, middle. The gap list after each
write, in bits:

```
after the last segment    [0:159]
after the first segment   [80:159]
after the middle segment  []
```

The first write lands at offset 20 and leaves everything below it missing. The
second fills bytes 0–9 and the gap shrinks to bits 80–159. The third closes it,
and `is_complete_range` turns true — at which point `assembled_chunk` hands
back all thirty bytes, `aa` ten times, then `bb`, then `cc`, in offset order.

Nobody sorted anything. The buffer keeps its regions ordered and coalesces
neighbours as they meet, so arrival order was never the receiver's problem.

## When segments disagree

Overlap is where reassembly gets opinionated, so the policy is an explicit
value on the write rather than a convention: `OVERWRITE` takes the new bytes,
`KEEP_EXISTING` keeps the old, and `REFUSE` — the default — throws.

Each has a protocol that wants it. `KEEP_EXISTING` is right for TCP
retransmission, where a duplicate segment should not be able to rewrite data
already delivered. `OVERWRITE` suits a cache or a reorder buffer where the
latest write is by definition the truth. `REFUSE` is the default because a
model whose segments overlap with *different bytes* and has not said which
should win has a bug, and the useful moment to find out is the write, not the
delivery.
