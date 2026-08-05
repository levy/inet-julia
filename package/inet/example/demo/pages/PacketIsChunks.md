# A packet is chunks

A packet here is an **envelope over immutable content**. The envelope is
mutable and cheap — it is what a protocol module pushes headers onto, pops them
off, tags and hands on. The content underneath is a tree of chunks that nobody
edits: a header is an immutable struct, a payload is often a `Filler` that
knows its length and owns no bytes at all, and a packet with a header in front
of a payload is a `Sequence` of the two.

That split is the whole design. Copying a packet copies the envelope and points
at the same content, so a thousand copies cost one payload.

## Building one

An application builds a packet by pushing a header onto a payload and hanging
its control information off the side as tags:

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "make_packet")>>
```

Note what is *not* in the content. The destination address, the creation time
and the hop count are tags: they travel with the packet through the network but
would never be on a wire, so they are not bytes. Only what a real link would
carry lives in `content`. INET makes the same distinction and this port keeps
it, because it is what stops a simulator-internal field from accidentally
having a wire format.

The packet that comes out is here — not a picture of one, and not a paste of
what `describe` printed on somebody's terminal. This is the object that call
returns, and you can open it up:

```pred-ref
<<packet("routed_ipv4")>>
```

Sixty bytes, and not one of them allocated: the header is a struct and the
payload is a `Filler` that knows it is forty zero bytes without storing them.

## Broadcasting it

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "broadcast_packet")>>
```

Ten receivers, ten packets — and one payload. Every duplicate's `content` is
the *same object*, which is what makes `dup` O(1) rather than O(payload).

## Forwarding each one

A hop changes the envelope and leaves the content alone:

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "forward!")>>
```

`popfirst!` then `pushfirst!` replaces the header. The old header still exists,
unchanged — it is an immutable value, so splicing a new one in front cannot
disturb anyone else holding the old. Run the broadcast and then forward every
copy, and each of the ten reads back a TTL of 63 while the original still reads
64. The payload was never touched by any of it.

So the score, for one payload broadcast to ten peers and forwarded a hop: ten
envelopes and ten headers copied, and zero payload bytes.

## Where this is headed

The dissection above is a **tree**, not a string — `describe` is one rendering
of it, and `dissect` hands you the tree itself, with each entry's kind, label,
length and quality. A projected, navigable view of that tree is the obvious
next thing to build here, and `Inspect.jl` was written with that in mind rather
than as a pretty-printer.
