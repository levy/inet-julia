# IEEE 802.2 LLC

Three octets, or four. The second octet of the control field is there only when
the low two bits of the first are not both set, so the header's own data decides
how long the header is — and one clause says so for the reader and the writer at
once.

```pred-ref
<<header_view("Ieee8022LlcHeader")>>
```
