# ============================================================================
# The IEEE 802.15.4 MAC header, as INET writes it.
#
# This is the one file where the declaration follows INET rather than the
# standard, and it says so. `Ieee802154MacHeaderSerializer` writes a frame that
# IEEE 802.15.4-2020 clause 7.2 would not recognise:
#
# * The frame control field is pinned to 0xCC01 — a data frame with both
#   addressing modes set to the sixty-four-bit extended form. INET asserts that
#   value on the way in, so no other frame reads.
# * The addresses are then written as six octets and two of padding, not as
#   the eight octets an extended address has.
# * The source PAN identifier carries the payload protocol number instead.
#   INET's own comment on that line reads `FIXME TODO KLUDGE: The IEEE
#   802.15.4 header does not contain information about the payload protocol
#   type.`
#
# Declaring the standard's frame here would be a different format that no INET
# capture contains. So this declares what INET writes, names each departure,
# and leaves the real frame for the day a model needs it.
#
# The whole header is little-endian, which is what IEEE 802.15.4 specifies and
# what makes it the first header in this library that is not network order.
# ============================================================================

"A data frame with both addresses in the extended form — the only frame INET writes."
const IEEE802154_FRAME_CONTROL = 0xcc01

"INET writes the broadcast PAN identifier and reads it back without looking."
const IEEE802154_BROADCAST_PAN = 0xffff

"""
    Ieee802154MacHeader(; source, destination, sequence_number, network_protocol)

The header INET writes for IEEE 802.15.4, twenty-three octets and
little-endian.

`network_protocol` sits where the standard puts the source PAN identifier. The
two padding fields sit where the remaining two octets of an extended address
would be.
"""
@header Ieee802154MacHeader begin
    frame_control       :: Constant{U16, IEEE802154_FRAME_CONTROL}
    sequence_number     :: U8  = 0
    destination_pan     :: U16 = IEEE802154_BROADCAST_PAN
    destination         :: MacAddress
    destination_padding :: U16 = 0
    network_protocol    :: U16 = 0
    source              :: MacAddress
    source_padding      :: U16 = 0
end

byte_order(::Type{Ieee802154MacHeader}) = :le
