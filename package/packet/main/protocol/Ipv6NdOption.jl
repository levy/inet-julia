# ============================================================================
# The Neighbor Discovery options — RFC 4861, section 4.6.
#
# Every option is a type octet, a length octet and a value. The length is in
# units of eight octets and counts the type and the length octets too, so the
# smallest option is eight octets and no option is zero. RFC 4861 says a
# receiver must discard a message that carries a zero length, and the option
# reader here refuses it for the same reason: an option of no width would never
# end the list.
#
# The list runs to the end of the ICMPv6 message. Nothing inside the message
# says where it stops — the IPv6 payload length does — so the list takes no
# window and reads what is there.
#
# The spelling follows RFC 4861, which writes "Neighbor". INET writes
# "Neighbour".
# ============================================================================

const IPV6ND_SOURCE_LINK_LAYER_ADDRESS = 1
const IPV6ND_TARGET_LINK_LAYER_ADDRESS = 2
const IPV6ND_PREFIX_INFORMATION        = 3
const IPV6ND_REDIRECTED_HEADER         = 4
const IPV6ND_MTU                       = 5

"The Neighbor Discovery options — one shape, and the type octet says which."
abstract type Ipv6NdOption <: Fields end

"""
    Ipv6NdSourceLinkLayerAddress(; address)

The Source Link-Layer Address option, eight octets — RFC 4861 section 4.6.1.
It tells the receiver the sender's link-layer address, which is what saves a
neighbour solicitation of its own.
"""
@header Ipv6NdSourceLinkLayerAddress <: Ipv6NdOption begin
    type    :: Constant{U8, IPV6ND_SOURCE_LINK_LAYER_ADDRESS}
    length  :: Constant{U8, 1}
    address :: MacAddress
end

"""
    Ipv6NdTargetLinkLayerAddress(; address)

The Target Link-Layer Address option, eight octets — RFC 4861 section 4.6.1.
A neighbour advertisement carries it, and it is the answer to the address
resolution the solicitation asked for.
"""
@header Ipv6NdTargetLinkLayerAddress <: Ipv6NdOption begin
    type    :: Constant{U8, IPV6ND_TARGET_LINK_LAYER_ADDRESS}
    length  :: Constant{U8, 1}
    address :: MacAddress
end

"""
    Ipv6NdPrefixInformation(; prefix, prefix_length, valid_lifetime, …)

The Prefix Information option, thirty-two octets — RFC 4861 section 4.6.2. A
router advertisement carries one for each prefix on the link, and a host builds
its address from it.

`on_link` is the L bit, `autonomous` is the A bit, and `router_address` is the
R bit that RFC 6275 section 7.2 adds for a home agent.
"""
@header Ipv6NdPrefixInformation <: Ipv6NdOption begin
    type               :: Constant{U8, IPV6ND_PREFIX_INFORMATION}
    length             :: Constant{U8, 4}
    prefix_length      :: U8
    on_link            :: Bool = false
    autonomous         :: Bool = false
    router_address     :: Bool = false
    reserved           :: U5   = 0
    valid_lifetime     :: U32
    preferred_lifetime :: U32
    reserved2          :: U32  = 0
    prefix             :: Ipv6Address
end

"""
    Ipv6NdMtu(; mtu)

The MTU option, eight octets — RFC 4861 section 4.6.4. A router advertises it
where the link's own MTU is not what a host would assume.
"""
@header Ipv6NdMtu <: Ipv6NdOption begin
    type     :: Constant{U8, IPV6ND_MTU}
    length   :: Constant{U8, 1}
    reserved :: U16 = 0
    mtu      :: U32
end

"""
    Ipv6NdOptionRaw(; type, data)

An option this library does not model. It keeps its type and its bytes, and it
pads to the eight-octet unit the length octet counts in.
"""
@header Ipv6NdOptionRaw <: Ipv6NdOption begin
    type    :: U8
    length  :: U8 = 1
        derive(cld(measure_header(h), 64))
    data    :: Octets = UInt8[]
        length(Bytes(8) * length - Bytes(2))
    padding :: Pad{Bytes(8), 0x00}
end

list_options(::Type{Ipv6NdOption}) =
    (Ipv6NdSourceLinkLayerAddress, Ipv6NdTargetLinkLayerAddress,
     Ipv6NdPrefixInformation, Ipv6NdMtu)
find_raw_option(::Type{Ipv6NdOption}) = Ipv6NdOptionRaw
