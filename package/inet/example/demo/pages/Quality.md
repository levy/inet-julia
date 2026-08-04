# Knowing what you know

Real receivers do not always get whole, correct packets. A frame arrives
truncated; a checksum fails; a chunk is a stand-in for something the model
never bothered to represent exactly. A simulator has to say which of those has
happened, and the honest answer is a property of the *data*, not a flag in some
module's local state.

Every chunk here carries a **quality**: three monotone bits — `incomplete`,
`incorrect`, `misrepresented` — joined with `⊔`. Monotone means the flags only
ever accumulate. A complete chunk sliced out of an incomplete one is
incomplete; a sequence is as bad as its worst member. Nothing quietly recovers.

## A header a receiver could not finish

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "truncated_packet")>>
```

Marking wraps rather than mutates. The `Ipv4Header` inside is the same
immutable value it always was — that is what keeps headers cheap and sharable —
and the mark rides in a thin envelope around it. From the outside the packet
reports `Quality(incomplete)`, and its dissection shows where the mark is:

```
Packet(data=60B)  [60B, Quality(incomplete)]
  Sequence(2)  [60B, Quality(incomplete)]
    Marked(Ipv4Header)  [20B, Quality(incomplete)]
      Ipv4Header  [20B]
        ttl = 64
    Filler(fill=0)  [40B]
```

## Asking for it anyway

`peek` is strict by default. It will not hand back data it knows is imperfect
unless the caller says which imperfection they are willing to accept:

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "strict_peek")>>
```

The refusal names the flag that stopped it and the keyword that would let it
through:

```
peek(Ipv4Header): source is INCOMPLETE. Pass `incomplete = true` to accept.
```

With `incomplete = true` the same call reads the header and returns a TTL of
64. Nothing about the data changed — what changed is that the caller has now
said, at the call site, in the source anyone reviewing this model will read,
that they know the header is incomplete and want it regardless.

The flags stay independent. Mark a header both incomplete and incorrect and
you get one chunk with both bits set — the join is commutative, so the order of
marking does not matter — and `incomplete = true` alone still refuses, on the
other flag:

```
peek(Ipv4Header): source is INCORRECT. Pass `incorrect = true` to accept.
```

## Why this page exists

This is the one page here with nothing to press. It is an argument.

A protocol model that silently parses garbage is how simulators lie. It does
not crash and it does not warn; it produces numbers, and the numbers are wrong
in a way that looks exactly like numbers that are right. The three bits and the
strict gate cost a keyword argument at the handful of call sites that genuinely
want damaged data, and in exchange every other call site is a place where
garbage cannot get through silently.

INET makes the same distinction with six `PF_ALLOW_*` bits. This port keeps the
semantics and spends them as named keyword arguments, because `incomplete =
true` reads as what it means and `PF_ALLOW_INCOMPLETE` has to be looked up.
