# ============================================================================
# UDP — RFC 768.
#
# Eight bytes, and the whole of it. There is no version of a UDP header that is
# longer, so this is the one format in the set that loses nothing by declaring
# fixed-size fields only.
#
# Neither computed field is computable from the header. `length` counts the
# header and the data together, and `checksum` covers a pseudo-header built
# from the IP addresses above. The UDP module sets both — which is what INET
# does, and what lets a capture round-trip byte for byte.
#
# A field named `length` is safe: field access never shadows `Base.length`.
# ============================================================================

const UDP_HEADER_BYTES = 8

"""
    UdpHeader(; source_port, destination_port, length, checksum)

The UDP header, 8 bytes. `length` counts this header and the data after it.
A `checksum` of zero means the sender did not compute one — RFC 768 gives the
value that second meaning, and `is_absent` asks the question.
"""
Base.@kwdef struct UdpHeader <: Fields
    source_port      :: Port
    destination_port :: Port
    length           :: U16        = UDP_HEADER_BYTES
    checksum         :: Checksum16 = 0
end
