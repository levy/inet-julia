# The packet, drawn the way the standard draws it

Every RFC that defines a header draws the same figure: bits across the top,
fields in boxes, the header flowing down the page. It is the picture a protocol
engineer already has in their head, and until now it lived only in the standard
— beside an implementation that might or might not agree with it.

Here it is not a picture. It is a projection of the packet itself:

```pred-ref
<<packet("ethernet_frame")>>
```

Nobody drew that. The marker splices **the packet**, and the figure is derived
from it by the same projection that draws a packet the renderer meets anywhere
else — in a document field, in a collection, on its own. Nothing converts it on
the way. Change the packet and the figure follows; there is no second
description of it to keep in step.

## Read the fourth row

```
 0x000c |           ethertype           #version|  ihl  |   dscp    |ecn|
        |         IPv4 (0x0800)         # 0100  | 0101  |  000000   |00 |
```

The `#` is where the Ethernet header ends and IPv4 begins — fourteen bytes in,
in the middle of a row. The grid is continuous over the whole packet rather
than one box per header, because that is what the wire is: no header waits for
a round number of bytes before the next one starts.

A `|` separates two fields of one header. A `#` separates two headers. That is
the whole notation.

## What each cell says

The name is on top and the value is under it, in the base the field's own
declaration chose:

- `dst` is a `MacAddress`, so it reads `0a:00:00:00:00:02` rather than as
  eleven digits.
- `protocol` is an `IpProtocol`, so 17 reads `UDP (17)`.
- `version` is four bits, so it reads as four bits: `0100`.
- `header_checksum` says `| hex` in its declaration, so it reads `0x0000`.

None of that is the figure's opinion. `header_layout` returns the name, the bit
offset, the bit width and the display base of every field, and `@header` emits
it from the same declaration it emits the codec from. The figure cannot
disagree with the bytes, because it is drawn from what wrote them.

A field wider than its cell falls back to a shorter base, and a value that
fits nowhere is cut and named in full in a legend under the figure. Nothing is
silently unreadable.

## The payload is not drawn

```
        +---------------------------------------------------------------+
 0x002a |                    Filler  32 B  fill=0x00                    |
        +---------------------------------------------------------------+
```

Thirty-two bytes of zeros is four rows of nothing; fifteen hundred is a hundred
and eighty-seven. A run the figure can measure but not name collapses to one
box, and the grid resumes after it — the gutter keeps counting the real offset,
so the frame check sequence still says `0x004a`.

## The same packet, as its tree

The figure is one view. The chunk tree is another, and both are views of one
object:

```pred-ref
<<packet_tree("ethernet_frame")>>
```

Fold a chunk there and the figure is unaffected: they are two projections, not
two copies.

## What to try

Count the bytes in the gutter against the byte offsets in
[Headers declare their own bytes](Headers.md) — `0x0008` is where the source
address starts, and the ninth byte of the IPv4 header is the TTL the routing
page decrements. Then look at the `dst` field spanning rows one and two, and
note that its value prints once, in the wider half, with a `~` where it
continues. A field does not fit a row boundary just because a figure would
prefer it to.
