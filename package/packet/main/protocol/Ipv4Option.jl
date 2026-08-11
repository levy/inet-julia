# ============================================================================
# The IPv4 options — RFC 791, section 3.1.
#
# An option is a type octet, and every type but End of Option List and No
# Operation is followed by a length octet that counts the whole option. The
# list runs to the end of the header, which `ihl` gives, and an End of Option
# List ends it sooner.
#
# An option this library does not know becomes an `Ipv4OptionRaw`, which keeps
# its type, its length and its bytes — so a datagram round-trips even where the
# model stops.
# ============================================================================

const IPOPTION_END_OF_OPTIONS        = 0
const IPOPTION_NO_OPTION             = 1
const IPOPTION_RECORD_ROUTE          = 7
const IPOPTION_TIMESTAMP             = 68
const IPOPTION_SECURITY              = 130
const IPOPTION_LOOSE_SOURCE_ROUTING  = 131
const IPOPTION_STREAM_ID             = 136
const IPOPTION_STRICT_SOURCE_ROUTING = 137
const IPOPTION_ROUTER_ALERT          = 148

"The IPv4 options — one shape, and the type octet says which."
abstract type Ipv4Option <: Fields end

"""
    Ipv4OptionEnd()

End of Option List, 1 byte. Everything after it in the header is padding.
"""
@header Ipv4OptionEnd <: Ipv4Option begin
    type :: Constant{U8, IPOPTION_END_OF_OPTIONS}
end

"""
    Ipv4OptionNop()

No Operation, 1 byte. It aligns the option that follows.
"""
@header Ipv4OptionNop <: Ipv4Option begin
    type :: Constant{U8, IPOPTION_NO_OPTION}
end

"""
    Ipv4OptionStreamId(; stream_id)

Stream Identifier, 4 bytes — RFC 791. Obsolete, and still on the wire.
"""
@header Ipv4OptionStreamId <: Ipv4Option begin
    type      :: Constant{U8, IPOPTION_STREAM_ID}
    length    :: Constant{U8, 4}
    stream_id :: U16
end

"""
    Ipv4OptionRouterAlert(; value)

Router Alert, 4 bytes — RFC 2113. A value of zero means "examine this packet".
"""
@header Ipv4OptionRouterAlert <: Ipv4Option begin
    type   :: Constant{U8, IPOPTION_ROUTER_ALERT}
    length :: Constant{U8, 4}
    value  :: U16 = 0
end

"""
    Ipv4OptionRecordRoute(; next_address_index, addresses)

Record Route, 3 bytes plus four for each address — RFC 791. `pointer` counts
octets from the start of the option, so it is four times the index plus four.
"""
@header Ipv4OptionRecordRoute <: Ipv4Option begin
    type      :: Constant{U8, IPOPTION_RECORD_ROUTE}
    length    :: U8
        derive(3 + 4 * Base.length(addresses))
    pointer   :: U8
        derive(4 + 4 * next_address_index)
    addresses :: Repeated{Ipv4Address}
        count((length - 3) ÷ 4)
    next_address_index :: Model{U8} = 0
end

"""
    Ipv4OptionRaw(; type, length, data)

An option this library does not model. It keeps everything, so the datagram
round-trips.
"""
@header Ipv4OptionRaw <: Ipv4Option begin
    type   :: U8
    length :: U8
        derive(2 + Base.length(data))
    data   :: Octets
        length(Bytes(length - 2))
end

list_options(::Type{Ipv4Option}) =
    (Ipv4OptionEnd, Ipv4OptionNop, Ipv4OptionStreamId, Ipv4OptionRouterAlert,
     Ipv4OptionRecordRoute)
find_raw_option(::Type{Ipv4Option}) = Ipv4OptionRaw
ends_option_list(::Type{Ipv4Option}, code) = code == IPOPTION_END_OF_OPTIONS
