# TCP — RFC 9293

Twenty octets before the options, and a data offset that counts what follows.
Nobody sets it: it derives from the header's own width, so a segment that
carries options gets the right value without anyone doing arithmetic.

```pred-ref
<<header_view("TcpHeader")>>
```
