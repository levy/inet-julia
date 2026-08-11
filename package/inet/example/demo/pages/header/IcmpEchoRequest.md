# ICMP echo request — RFC 792

One message of a family. Its first field is the base header every ICMP message
starts with — embedded, not inherited, because Julia has no struct inheritance
and does not need one. The reader takes the base, rewinds, and reads again as
the member the type octet names.

```pred-ref
<<header_view("IcmpEchoRequest")>>
```
