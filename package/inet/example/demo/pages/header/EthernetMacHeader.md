# Ethernet MAC — IEEE 802.3

Fourteen octets: two addresses and one field with two readings. There is no
macro over this declaration at all — a plain Julia struct is already a complete
wire format, and everything below is derived from those three fields.

```pred-ref
<<header_view("EthernetMacHeader")>>
```
