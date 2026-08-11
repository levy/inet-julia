# IPv6 — RFC 8200

Forty octets, of which thirty-two are two addresses that no machine word holds.
The flow label is twenty bits, the traffic class is eight, and the version is
four — three fields sharing the first word, none of them on a byte boundary.

```pred-ref
<<header_view("Ipv6Header")>>
```
