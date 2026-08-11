# UDP — RFC 768

The smallest header there is: two ports a caller states, and two fields the
declaration decides, because a datagram cannot know either on its own.

The datagram this page is about, written as the Julia that builds it:

```julia
UdpHeader(source_port = 5000, destination_port = 53)
```

And the same call, drawn the way RFC 768 draws it — not a picture of that code,
but that code, constructed and projected:

```pred-ref
<<packet(UdpHeader(source_port = 5000, destination_port = 53))>>
```

`length` and `checksum` are absent from the call and present in the figure, at
the defaults the declaration gives them: eight octets, and a checksum of zero,
which RFC 768 reads as "the sender did not compute one".

Everything else about the format is below, and none of it is written here
either.

```pred-ref
<<header_view("UdpHeader")>>
```
