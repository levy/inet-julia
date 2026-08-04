# Headers declare their own bytes

A header is declared once. The declaration yields the struct *and* its
bit-exact wire codec — there is no second description of the layout to keep in
step, and no code generation step between the two.

```pred-ref
<<file("../../../packet/example/demo_headers.jl")>>
```

The `| 4` and `| 13` are bit widths. Fields without one take their type's
width, so `ttl :: UInt8` is eight bits and `total_length :: UInt16` is sixteen.
`version`, `ihl`, `dscp` and `ecn` pack into the first two bytes exactly as
IPv4 says they do, and the `flags`/`frag_offset` pair splits a byte boundary
three bits in — which is the sort of thing a hand-written codec gets wrong once
and then nobody notices.

## The bytes those fields become

Serialise a packet built with that header and the first twenty bytes are the
header, on the wire, in network order:

```
45 00 00 3c 00 00 00 00 40 11 00 00 0a 00 00 01 0a 00 00 02
```

Read it against the declaration. `45` is `version = 4` and `ihl = 5` sharing a
byte. `00 3c` is `total_length = 60`. The **`40` in the ninth byte is the TTL**
— sixty-four — and the `11` beside it is `protocol = 17`, UDP. The last eight
bytes are the two addresses, `10.0.0.1` and `10.0.0.2`, which is what
`167772161` and `167772162` look like when you stop reading them as decimal.

Decrement the TTL and exactly one byte changes, the ninth, from `40` to `3f`.
Nothing else in the packet moves.

## Reading a header as the wrong header

Every `peek` names the type it wants. Naming the type that is actually there is
the ordinary case. Naming a *different* header type is almost always a bug, so
it is refused:

```pred-ref
<<definition(file("../../../packet/example/packet_api_demo.jl"), "reinterpretation_guard")>>
```

The refusal says so in as many words:

```
peek: refusing to reinterpret Ipv4Header as UdpHeader.
Reading one Fields type as another is almost always a bug — an Ipv4Header is
laid out differently from a UdpHeader. If you really mean it, pass
`reinterpret = true`; the shape is deliberately awkward.
```

Pass `reinterpret = true` and it goes through, and what comes out shows why the
guard is worth having: `src_port = 17664`, which is `45 00` — the version and
header-length nibbles — read as a port number, and `dst_port = 60`, which is
the IPv4 total length. Plausible-looking integers, all of them wrong.

Bytes are not gated this way. Deserialising a header out of raw bytes needs no
opt-in at all, because bytes carry no claim about what they are; it is only a
header claiming to be a *different* header that has to be asked for twice.

## What to try

Look at the ninth byte, then look at `ttl :: UInt8` in the declaration above,
and note that nothing in this repository connects the two except the `@header`
macro. Then read the guard's refusal again and ask what the alternative is: a
simulator that silently reads twenty bytes of IPv4 as a UDP header and reports
traffic on port 17664.
