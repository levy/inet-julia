# ============================================================================
# Building an Ethernet frame, and nothing else.
#
# The chunks themselves — `EthernetMacHeader`, `EthernetFcs`, the ethertypes
# and the frame-size constants — are declared by `InetPacket` in
# `packet/main/protocol/Ethernet.jl`, because the wire format of Ethernet is
# not a property of 10BASE-T1S. This file holds what is: how this model wraps a
# payload into a frame.
#
# Faithful to INET's on-wire framing:
#   EthernetMacHeader  14 B — dst MAC (6) + src MAC (6) + ethertype/length (2)
#   payload            variable
#   padding            fill to MIN_ETHERNET_FRAME_BYTES = 64 counting header + FCS
#   EthernetFcs        4 B — declared mode; zero-filled
#
# The 8-byte EthernetPhyHeader (preamble + SFD) is NOT added here — that is the
# PHY's job. Same split as INET (`EthernetCsmaPhy::encapsulate`).
#
# This model carries a MAC address as a `UInt64`, which is what the PLCA and
# MAC machines compare and what a `SourceConfig` names. `MacAddress` converts
# from one, so the header gets a typed address and the machines keep their
# integer.
# ============================================================================

"""
    build_ethernet_frame(src, dst, ethertype, payload::Chunk) -> Packet

Wrap `payload` into a Packet whose content is
`EthernetMacHeader + payload + optional padding + EthernetFcs`, matching
INET's `EthernetCsmaMac::addPaddingAndSetFcs`. Padding brings the total
frame length (header + payload + padding + FCS) up to `MIN_ETHERNET_FRAME_BYTES`
if it's below.

FCS is zero-filled (declared mode — `fcsMode = "declared"`, INET's default).
"""
function build_ethernet_frame(src::Integer, dst::Integer,
                              ethertype::Union{Integer, EtherType}, payload::Chunk)
    header = EthernetMacHeader(MacAddress(dst), MacAddress(src), EtherType(ethertype))
    pk = Packet(payload)
    pushfirst!(pk, header)
    # Compute what the frame would be with just header + payload + FCS.
    tentative_bytes = data_length(pk).bits >> 3 + 4      # + FCS
    if tentative_bytes < MIN_ETHERNET_FRAME_BYTES
        pad_bytes = MIN_ETHERNET_FRAME_BYTES - tentative_bytes
        push!(pk, Filler(Bytes(pad_bytes); fill = 0x00))
    end
    push!(pk, EthernetFcs(0x00000000))
    return pk
end
