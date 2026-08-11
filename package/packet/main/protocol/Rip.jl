# ============================================================================
# The routing information protocol — RFC 2453.
#
# A message is four octets of header and then as many twenty-octet route
# entries as fit. Nothing counts them: RFC 2453 clause 3.6 says the number is
# what the datagram length leaves, so the list fills the message.
#
# The third and fourth octets are the "must be zero" field, and this library
# keeps them as one field rather than inventing an entry count for them, which
# is what the standard draws.
# ============================================================================

const RIP_REQUEST  = 1
const RIP_RESPONSE = 2

"The address family identifiers RIP uses — RFC 2453 clause 3.6."
const RIP_ADDRESS_FAMILY_NONE           = 0
const RIP_ADDRESS_FAMILY_INET           = 2
const RIP_ADDRESS_FAMILY_AUTHENTICATION = 0xffff

"A route entry is twenty octets — RFC 2453 clause 3.6."
const RIP_ENTRY_BYTES = 20

"""
    RipEntry(; address, netmask, next_hop, metric, route_tag)

One route entry, twenty octets — RFC 2453 clause 3.6. A metric of sixteen means
the destination is unreachable.
"""
@header RipEntry begin
    address_family :: U16 = RIP_ADDRESS_FAMILY_INET
    route_tag      :: U16 = 0
    address        :: Ipv4Address
    netmask        :: Ipv4Address
    next_hop       :: Ipv4Address
    metric         :: U32 = 1
end

"""
    RipPacket(; command, entries, version)

A RIP message — RFC 2453 clause 3.6. The entries fill what is left of the
datagram, so no field counts them.
"""
@header RipPacket begin
    command :: U8  = RIP_RESPONSE
    version :: U8  = 2
    unused  :: U16 = 0
    entries :: Repeated{RipEntry} = RipEntry[]
end
