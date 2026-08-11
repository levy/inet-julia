# The IPv6 fragment header — RFC 8200 section 4.5

Eight octets, and most of them reserved. An extension header is a header like
any other here: it declares its fields, and the chain that carries it is the
packet's business rather than the declaration's.

```pred-ref
<<header_view("Ipv6FragmentHeader")>>
```
