# The headers the demos use, declared once.
#
# `@header` yields the struct AND its bit-exact wire codec from one
# declaration: `serialize`, `deserialize` and `chunk_length` come with it, so
# there is no second description of the layout to keep in step.
#
# A bare `Type` after the name is that type's full width; `| n` narrows a field
# to n bits, which is how the packed fields of a real header are spelled.

# IPv4, exactly as RFC 791 lays it out. The first two bytes are four packed
# fields, and flags/frag_offset split a byte boundary three bits in.
@header Ipv4Header begin
    version        :: UInt8  | 4
    ihl            :: UInt8  | 4
    dscp           :: UInt8  | 6
    ecn            :: UInt8  | 2
    total_length   :: UInt16
    identification :: UInt16
    flags          :: UInt8  | 3
    frag_offset    :: UInt16 | 13
    ttl            :: UInt8
    protocol       :: UInt8
    checksum       :: UInt16
    src_addr       :: UInt32
    dst_addr       :: UInt32
end

# UDP — the smallest header there is, and the second type the reinterpretation
# guard needs in order to have something to refuse. With one header type
# declared, "reading one header as another" cannot be demonstrated at all.
@header UdpHeader begin
    src_port   :: UInt16
    dst_port   :: UInt16
    udp_length :: UInt16
    checksum   :: UInt16
end
