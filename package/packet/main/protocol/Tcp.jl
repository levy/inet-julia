# ============================================================================
# TCP — RFC 9293, section 3.1.
#
# Twenty bytes, with `data_offset` fixed at 5: this library declares no options
# yet, so every TCP header it builds is the minimum one.
#
# The eight control bits are eight `Bool` fields rather than one byte with a
# mask. That is what §3.1 draws, it is what makes `syn` and `ack` readable at a
# call site, and it is what lets a view label each bit.
#
# RFC 9331 renames the top reserved bit to `AE` for accurate ECN. The four
# reserved bits are kept as one field; a model that needs `AE` narrows this
# field and adds it in the same declaration.
# ============================================================================

const TCP_MIN_DATA_OFFSET = 5              # 5 words of 32 bits = 20 bytes
const TCP_HEADER_BYTES    = 20

"""
    TcpHeader(; source_port, destination_port, sequence_number, …)

The TCP header, 20 bytes. Every field but the ports and the sequence number
carries a default, so a segment states only what it decides.
"""
Base.@kwdef struct TcpHeader <: Fields
    source_port           :: Port
    destination_port      :: Port
    sequence_number       :: U32
    acknowledgment_number :: U32        = 0
    data_offset           :: U4         = TCP_MIN_DATA_OFFSET
    reserved              :: U4         = 0
    cwr                   :: Bool       = false
    ece                   :: Bool       = false
    urg                   :: Bool       = false
    ack                   :: Bool       = false
    psh                   :: Bool       = false
    rst                   :: Bool       = false
    syn                   :: Bool       = false
    fin                   :: Bool       = false
    window                :: U16        = 0xffff
    checksum              :: Checksum16 = 0
    urgent_pointer        :: U16        = 0
end

"""
    list_tcp_flags(h::TcpHeader) -> String

The control bits a reader would name, as `SYN,ACK`. An empty string when none
is set.
"""
function list_tcp_flags(h::TcpHeader)
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
