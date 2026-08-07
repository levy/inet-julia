# ============================================================================
# UDP — RFC 768.
#
# Eight bytes, and the whole of it. There is no version of a UDP header that is
# longer, so this is the one header in the set that loses nothing by declaring
# fixed-size fields only.
#
# `length` counts the header and the data together, which is why it is not the
# same number as the payload length. A field named `length` is safe: field
# access never shadows `Base.length`, and `Filler` and `Raw` already have one.
# ============================================================================

const UDP_HEADER_BYTES = 8

"""
    UdpHeader(; src_port, dst_port, length, checksum = 0)

The UDP header, 8 bytes. `length` counts this header and the data after it.
`checksum` is declared, never computed.
"""
@header UdpHeader begin
    src_port :: PortNumber
    dst_port :: PortNumber
    length   :: UInt16
    checksum :: UInt16 | 16 | hex = 0x0000
end
