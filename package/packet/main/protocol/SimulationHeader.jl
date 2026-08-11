# ============================================================================
# The headers INET invented for simulation.
#
# Every other file here is written from a standard, and INET is the second
# opinion. The formats here have no standard behind them: they are INET's own,
# so INET is the specification and its serializer is the source.
#
# They all share one shape. The first field is the header's own length, and
# whatever the named fields do not use is filler up to that length — INET
# writes the question mark, 0x3f, so that a capture shows at a glance which
# octets carry nothing. A model chooses the total length; the filler is what
# reaches it.
#
# This library turns that around: the filler is a field, and the length derives
# from it. The direction that matters is the one that cannot be wrong, and a
# derived length can never disagree with the octets beside it.
#
#     header = AckingMacHeader(source = "0a:00:00:00:00:01",
#                              destination = "0a:00:00:00:00:02",
#                              filler = fill(SIMULATION_FILLER, 17))
#     chunk_length(header)        # 40 bytes: the 23 named ones and 17 more
#
# The length field counts bits in some and octets in others, which is why each
# one states its own unit.
# ============================================================================

"The octet INET writes where a header carries nothing — the question mark."
const SIMULATION_FILLER = 0x3f

"The named fields of an acking MAC header, before its filler."
const ACKING_MAC_HEADER_BYTES = 23

"""
    AckingMacHeader(; source, destination, network_protocol, source_module_id, filler)

The header of INET's idealised MAC — `AckingMacHeaderSerializer`.

Its length field counts octets, where the physical-layer ones count bits. The source
address comes before the destination, which is the opposite of IEEE 802.3;
INET wrote it that way and this follows.
"""
@header AckingMacHeader begin
    header_length    :: U8 = ACKING_MAC_HEADER_BYTES
        derive(measure_header(h) ÷ 8)
    source           :: MacAddress
    destination      :: MacAddress
    network_protocol :: U16 = 0
    source_module_id :: U64 = 0
    filler           :: Octets = UInt8[]
        until(Bytes(header_length))
end

"""
    ShortcutMacHeader(; payload_protocol, filler)

The header of INET's shortcut MAC, which delivers a frame to a peer without a
medium — `ShortcutMacHeaderSerializer`. Its length field counts bits.
"""
@header ShortcutMacHeader begin
    header_length    :: U16 = 32
        derive(measure_header(h))
    payload_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    GenericPhyHeader(; payload_protocol, filler)

The header of INET's generic physical layer — `GenericPhyHeaderSerializer`.
Its length field counts bits, and INET fills with zero bits rather than with
question marks.
"""
@header GenericPhyHeader begin
    header_length    :: U16 = 32
        derive(measure_header(h))
    payload_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    ShortcutPhyHeader(; payload_protocol, filler)

The header of INET's shortcut physical layer —
`ShortcutPhyHeaderSerializer`. It has the same four octets as
`GenericPhyHeader` and a different protocol number.
"""
@header ShortcutPhyHeader begin
    header_length    :: U16 = 32
        derive(measure_header(h))
    payload_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    ApskPhyHeader(; payload_length, fcs, payload_protocol, filler)

The header of INET's amplitude and phase shift keying physical layer —
`ApskPhyHeaderSerializer`. Both of its length fields count bits, and
`payload_length` measures what follows the header, not the header.
"""
@header ApskPhyHeader begin
    header_length    :: U16 = 64
        derive(measure_header(h))
    payload_length   :: U16 = 0
    fcs              :: Checksum16 = 0
    fcs_mode         :: Model{ChecksumMode} = CHECKSUM_DECLARED
    payload_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    build_filler(total::BitLength, named::BitLength)::Vector{UInt8}

The filler that takes a header of `named` bits up to `total` bits. It is the
answer to "I want a forty-octet header", which is how a simulation model
thinks, expressed in the field the header actually has.
"""
function build_filler(total::BitLength, named::BitLength)
    spare = bits(total) - bits(named)
    spare >= 0 ||
        error("build_filler: a header of $(named) does not fit in $(total)")
    spare % 8 == 0 ||
        error("build_filler: $(spare) bits is not a whole number of octets")
    return fill(SIMULATION_FILLER, spare ÷ 8)
end

# ---------- the application payloads, the same shape again -------------------
#
# Three more of INET's own formats state their own length and fill the rest.
# They are payloads rather than headers, and the shape is the one above: the
# first field is the length in octets, and the filler reaches it.

"The named fields of each application payload, before its filler."
const APPLICATION_PACKET_BYTES = 8
const ETHER_APP_PACKET_BYTES   = 12

"""
    ApplicationPacket(; sequence_number, filler)

The payload INET's generic applications send — `ApplicationPacketSerializer`.
Eight octets of named fields and as many more as the model asked for.
"""
@header ApplicationPacket begin
    packet_length   :: U32 = APPLICATION_PACKET_BYTES
        derive(measure_header(h) ÷ 8)
    sequence_number :: U32 = 0
    filler          :: Octets = UInt8[]
        until(Bytes(packet_length))
end

"""
    EtherAppRequest(; request_id, response_bytes, filler)

The request of INET's Ethernet application — `EtherAppReqSerializer`.
`response_bytes` is how large a reply the sender wants.
"""
@header EtherAppRequest begin
    packet_length  :: U32 = ETHER_APP_PACKET_BYTES
        derive(measure_header(h) ÷ 8)
    request_id     :: U32 = 0
    response_bytes :: U32 = 0
    filler         :: Octets = UInt8[]
        until(Bytes(packet_length))
end

"""
    EtherAppResponse(; request_id, frame_count, filler)

The reply of INET's Ethernet application — `EtherAppRespSerializer`. It answers
one request, and `frame_count` says how many frames the reply takes.
"""
@header EtherAppResponse begin
    packet_length :: U32 = ETHER_APP_PACKET_BYTES
        derive(measure_header(h) ÷ 8)
    request_id    :: U32 = 0
    frame_count   :: U32 = 0
    filler        :: Octets = UInt8[]
        until(Bytes(packet_length))
end
