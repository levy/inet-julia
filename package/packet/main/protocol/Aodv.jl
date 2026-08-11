# ============================================================================
# Ad hoc on-demand distance vector routing — RFC 3561.
#
# Four control packets, and the first octet says which. RFC 3561 defines them
# over IPv4; INET adds an IPv6 form of each with a type code of its own, and
# those are declared here too because they are four more wire formats.
#
# One difference from INET, and it is a model detail rather than a format one:
# `AodvControlPacketsSerializer` writes the unreachable node list backwards,
# from the last entry to the first. RFC 3561 clause 5.3 draws the list in
# order, and a reader that reverses on the way in and not on the way out would
# turn the list around on every hop. It is declared in order here.
# ============================================================================

const AODV_RREQ          = 1
const AODV_RREP          = 2
const AODV_RERR          = 3
const AODV_RREP_ACK      = 4
const AODV_RREQ_IPV6     = 16
const AODV_RREP_IPV6     = 17
const AODV_RERR_IPV6     = 18
const AODV_RREP_ACK_IPV6 = 19

"The AODV control packets — one wire format, and the first octet says which."
abstract type AodvControlPacket <: Fields end

"""
    AodvCommon(; packet_type)

The one octet an AODV reader looks at to decide which packet arrived.
"""
@header AodvCommon <: AodvControlPacket begin
    packet_type :: U8 = AODV_RREQ
end

"""
    AodvRreq(; destination, originator, rreq_id, hop_count, …)

A route request over IPv4, twenty-four octets — RFC 3561 clause 5.1.

`unknown_sequence_number` is the U flag, which says the originator does not
know a sequence number for the destination.
"""
@header AodvRreq <: AodvControlPacket begin
    base                    :: AodvCommon = AodvCommon(packet_type = AODV_RREQ)
    join                    :: Bool = false
    repair                  :: Bool = false
    gratuitous_reply        :: Bool = false
    destination_only        :: Bool = false
    unknown_sequence_number :: Bool = false
    reserved                :: U11  = 0
    hop_count               :: U8   = 0
    rreq_id                 :: U32  = 0
    destination             :: Ipv4Address
    destination_sequence    :: U32  = 0
    originator              :: Ipv4Address
    originator_sequence     :: U32  = 0
end

"""
    AodvRreqIpv6(; destination, originator, rreq_id, hop_count, …)

A route request over IPv6, forty-eight octets. The addresses move after the
sequence numbers, which is what INET writes.
"""
@header AodvRreqIpv6 <: AodvControlPacket begin
    base                    :: AodvCommon = AodvCommon(packet_type = AODV_RREQ_IPV6)
    join                    :: Bool = false
    repair                  :: Bool = false
    gratuitous_reply        :: Bool = false
    destination_only        :: Bool = false
    unknown_sequence_number :: Bool = false
    reserved                :: U11  = 0
    hop_count               :: U8   = 0
    rreq_id                 :: U32  = 0
    destination_sequence    :: U32  = 0
    originator_sequence     :: U32  = 0
    destination             :: Ipv6Address
    originator              :: Ipv6Address
end

"""
    AodvRrep(; destination, originator, lifetime, hop_count, …)

A route reply over IPv4, twenty octets — RFC 3561 clause 5.2. `lifetime` is in
milliseconds.
"""
@header AodvRrep <: AodvControlPacket begin
    base                 :: AodvCommon = AodvCommon(packet_type = AODV_RREP)
    repair               :: Bool = false
    acknowledgment_required :: Bool = false
    reserved             :: U9   = 0
    prefix_size          :: U5   = 0
    hop_count            :: U8   = 0
    destination          :: Ipv4Address
    destination_sequence :: U32  = 0
    originator           :: Ipv4Address
    lifetime             :: U32  = 0
end

"""
    AodvRrepIpv6(; destination, originator, lifetime, hop_count, …)

A route reply over IPv6, forty-four octets. Its prefix size takes seven bits
where the IPv4 form takes five, because an IPv6 prefix goes up to 128.
"""
@header AodvRrepIpv6 <: AodvControlPacket begin
    base                 :: AodvCommon = AodvCommon(packet_type = AODV_RREP_IPV6)
    repair               :: Bool = false
    acknowledgment_required :: Bool = false
    reserved             :: U7   = 0
    prefix_size          :: U7   = 0
    hop_count            :: U8   = 0
    destination_sequence :: U32  = 0
    destination          :: Ipv6Address
    originator           :: Ipv6Address
    lifetime             :: U32  = 0
end

"""
    AodvUnreachableNode(; address, sequence_number)

One entry of a route error's list, eight octets — RFC 3561 clause 5.3.
"""
@header AodvUnreachableNode begin
    address         :: Ipv4Address
    sequence_number :: U32 = 0
end

"""
    AodvUnreachableNodeIpv6(; address, sequence_number)

One entry of an IPv6 route error's list, twenty octets. INET writes the
sequence number first here and the address first in the IPv4 form.
"""
@header AodvUnreachableNodeIpv6 begin
    sequence_number :: U32 = 0
    address         :: Ipv6Address
end

"""
    AodvRerr(; unreachable_nodes, no_delete)

A route error over IPv4 — RFC 3561 clause 5.3. Four octets and eight more for
each destination that became unreachable. There is always at least one.
"""
@header AodvRerr <: AodvControlPacket begin
    base              :: AodvCommon = AodvCommon(packet_type = AODV_RERR)
    no_delete         :: Bool = false
    reserved          :: U15  = 0
    destination_count :: U8   = 1
        derive(Base.length(unreachable_nodes))
    unreachable_nodes :: Repeated{AodvUnreachableNode} = AodvUnreachableNode[]
        count(destination_count)
end

"""
    AodvRerrIpv6(; unreachable_nodes, no_delete)

A route error over IPv6. Four octets and twenty more for each destination.
"""
@header AodvRerrIpv6 <: AodvControlPacket begin
    base              :: AodvCommon = AodvCommon(packet_type = AODV_RERR_IPV6)
    no_delete         :: Bool = false
    reserved          :: U15  = 0
    destination_count :: U8   = 1
        derive(Base.length(unreachable_nodes))
    unreachable_nodes :: Repeated{AodvUnreachableNodeIpv6} = AodvUnreachableNodeIpv6[]
        count(destination_count)
end

"""
    AodvRrepAck()

A route reply acknowledgement, two octets — RFC 3561 clause 5.4.
"""
@header AodvRrepAck <: AodvControlPacket begin
    base     :: AodvCommon = AodvCommon(packet_type = AODV_RREP_ACK)
    reserved :: U8 = 0
end

"""
    AodvRrepAckIpv6()

A route reply acknowledgement over IPv6, two octets.
"""
@header AodvRrepAckIpv6 <: AodvControlPacket begin
    base     :: AodvCommon = AodvCommon(packet_type = AODV_RREP_ACK_IPV6)
    reserved :: U8 = 0
end

list_variants(::Type{AodvControlPacket}) =
    (AodvRreq, AodvRrep, AodvRerr, AodvRrepAck,
     AodvRreqIpv6, AodvRrepIpv6, AodvRerrIpv6, AodvRrepAckIpv6)
variant_base(::Type{AodvControlPacket}) = AodvCommon

matches_variant(::Type{AodvRreq}, base)     = base.packet_type == AODV_RREQ
matches_variant(::Type{AodvRrep}, base)     = base.packet_type == AODV_RREP
matches_variant(::Type{AodvRerr}, base)     = base.packet_type == AODV_RERR
matches_variant(::Type{AodvRrepAck}, base)  = base.packet_type == AODV_RREP_ACK
matches_variant(::Type{AodvRreqIpv6}, base) = base.packet_type == AODV_RREQ_IPV6
matches_variant(::Type{AodvRrepIpv6}, base) = base.packet_type == AODV_RREP_IPV6
matches_variant(::Type{AodvRerrIpv6}, base) = base.packet_type == AODV_RERR_IPV6
matches_variant(::Type{AodvRrepAckIpv6}, base) = base.packet_type == AODV_RREP_ACK_IPV6

# ---------- destination-sequenced distance vector, INET's own hello ----------

"""
    DsdvHello(; source, next_hop, sequence_number, hop_distance)

The hello message of INET's DSDV implementation, sixteen octets. DSDV has no
standard packet format, so `DsdvHelloSerializer` is the specification.
"""
@header DsdvHello begin
    source          :: Ipv4Address
    sequence_number :: U32 = 0
    next_hop        :: Ipv4Address
    hop_distance    :: U32 = 0
end
