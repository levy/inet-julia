# ============================================================================
# TCP — RFC 9293, section 3.1.
#
# Twenty bytes, with `data_offset` fixed at 5: this library declares no
# options, so every TCP header it builds is the minimum one.
#
# The eight control bits are eight one-bit fields rather than one byte with a
# mask. That is what the standard draws, it is what makes `syn` and `ack`
# readable at a call site, and it is what lets the diagram label each bit.
#
# RFC 9331 renames the top reserved bit to `AE` for accurate ECN. The four
# reserved bits are kept as one field; a model that needs `AE` narrows this
# field and adds it in the same declaration.
# ============================================================================

const TCP_MIN_DATA_OFFSET = UInt8(5)       # 5 words of 32 bits = 20 bytes
const TCP_HEADER_BYTES = 20

"""
    TcpHeader(; src_port, dst_port, sequence_number, …)

The TCP header, 20 bytes. Every field but the ports and the sequence number
carries a default, so a segment states only what it decides.
"""
@header TcpHeader begin
    src_port              :: PortNumber
    dst_port              :: PortNumber
    sequence_number       :: UInt32
    acknowledgment_number :: UInt32      = 0x00000000
    data_offset           :: UInt8  | 4  = TCP_MIN_DATA_OFFSET
    reserved              :: UInt8  | 4  = 0x00
    cwr                   :: Bool   | 1  = false
    ece                   :: Bool   | 1  = false
    urg                   :: Bool   | 1  = false
    ack                   :: Bool   | 1  = false
    psh                   :: Bool   | 1  = false
    rst                   :: Bool   | 1  = false
    syn                   :: Bool   | 1  = false
    fin                   :: Bool   | 1  = false
    window                :: UInt16      = 0xffff
    checksum              :: UInt16 | 16 | hex = 0x0000
    urgent_pointer        :: UInt16      = 0x0000
end

"""
    tcp_flags(h::TcpHeader) -> String

The control bits a reader would name, as `SYN,ACK`. An empty string when none
is set.
"""
function tcp_flags(h::TcpHeader)
    set = String[]
    h.cwr && push!(set, "CWR")
    h.ece && push!(set, "ECE")
    h.urg && push!(set, "URG")
    h.ack && push!(set, "ACK")
    h.psh && push!(set, "PSH")
    h.rst && push!(set, "RST")
    h.syn && push!(set, "SYN")
    h.fin && push!(set, "FIN")
    return join(set, ",")
end
