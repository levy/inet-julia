# ============================================================================
# The TCP options — RFC 9293, section 3.2.
#
# An option is a kind octet, and every kind but End of Option List and No
# Operation is followed by a length octet that counts the whole option. The
# list runs to the end of the header, which `data_offset` gives.
# ============================================================================

const TCPOPTION_END_OF_OPTION_LIST   = 0
const TCPOPTION_NO_OPERATION         = 1
const TCPOPTION_MAXIMUM_SEGMENT_SIZE = 2
const TCPOPTION_WINDOW_SCALE         = 3
const TCPOPTION_SACK_PERMITTED       = 4
const TCPOPTION_SACK                 = 5
const TCPOPTION_TIMESTAMP            = 8

"The TCP options — one shape, and the kind octet says which."
abstract type TcpOption <: Fields end

"End of Option List, 1 byte."
@header TcpOptionEnd <: TcpOption begin
    kind :: Constant{U8, TCPOPTION_END_OF_OPTION_LIST}
end

"No Operation, 1 byte. It aligns the option that follows."
@header TcpOptionNop <: TcpOption begin
    kind :: Constant{U8, TCPOPTION_NO_OPERATION}
end

"""
    TcpOptionMaxSegmentSize(; max_segment_size)

Maximum Segment Size, 4 bytes — RFC 9293 §3.2.
"""
@header TcpOptionMaxSegmentSize <: TcpOption begin
    kind             :: Constant{U8, TCPOPTION_MAXIMUM_SEGMENT_SIZE}
    length           :: Constant{U8, 4}
    max_segment_size :: U16
end

"""
    TcpOptionWindowScale(; window_scale)

Window Scale, 3 bytes — RFC 7323.
"""
@header TcpOptionWindowScale <: TcpOption begin
    kind         :: Constant{U8, TCPOPTION_WINDOW_SCALE}
    length       :: Constant{U8, 3}
    window_scale :: U8
end

"Selective Acknowledgement Permitted, 2 bytes — RFC 2018."
@header TcpOptionSackPermitted <: TcpOption begin
    kind   :: Constant{U8, TCPOPTION_SACK_PERMITTED}
    length :: Constant{U8, 2}
end

"""
    TcpOptionTimestamp(; sender_timestamp, echoed_timestamp)

Timestamps, 10 bytes — RFC 7323.
"""
@header TcpOptionTimestamp <: TcpOption begin
    kind             :: Constant{U8, TCPOPTION_TIMESTAMP}
    length           :: Constant{U8, 10}
    sender_timestamp :: U32
    echoed_timestamp :: U32 = 0
end

"""
    TcpOptionRaw(; kind, length, data)

An option this library does not model, kept whole.
"""
@header TcpOptionRaw <: TcpOption begin
    kind   :: U8
    length :: U8 = 0
        derive(2 + Base.length(data))
    data   :: Octets
        length(Bytes(length - 2))
end

list_options(::Type{TcpOption}) =
    (TcpOptionEnd, TcpOptionNop, TcpOptionMaxSegmentSize, TcpOptionWindowScale,
     TcpOptionSackPermitted, TcpOptionTimestamp)
find_raw_option(::Type{TcpOption}) = TcpOptionRaw
ends_option_list(::Type{TcpOption}, code) = code == TCPOPTION_END_OF_OPTION_LIST
