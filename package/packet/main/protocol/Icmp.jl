# ============================================================================
# ICMP — RFC 792, as a variant family.
#
# Every ICMP message starts with the same four bytes — type, code and checksum
# — and the type says what the four after them mean. INET writes those four
# bytes and then switches, copying the first three fields into the concrete
# header by hand once per case. Here the base is an embedded field, so each
# member declares its own fields once and nothing is copied.
#
# INET's `IcmpHeader` is eight bytes, not four: its `chunkLength` covers the
# four bytes every message has after the header, whatever they mean. A message
# whose type this library does not model therefore reads back as the base with
# those four bytes unmodelled, and is marked misrepresented.
# ============================================================================

const ICMP_ECHO_REPLY              = 0
const ICMP_DESTINATION_UNREACHABLE = 3
const ICMP_ECHO_REQUEST            = 8
const ICMP_TIME_EXCEEDED           = 11
const ICMP_PARAMETER_PROBLEM       = 12

const ICMP_DU_FRAGMENTATION_NEEDED = 4

"The ICMP messages — one wire format, and the type says which."
abstract type IcmpMessage <: Fields end

"""
    IcmpCommon(; type, code, checksum)

The four bytes every ICMP message starts with — RFC 792's type, code and
checksum. It is what a reader looks at to decide which message this is, and
every member embeds it.
"""
@header IcmpCommon begin
    type          :: U8
    code          :: U8         = 0
    checksum      :: Checksum16 = 0
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    IcmpHeader(; base, unused)

An ICMP message this library does not model, 8 bytes: the common four and the
four whose meaning its type decides. A message no member claims comes back as
this, marked misrepresented, with its bytes intact.
"""
@header IcmpHeader <: IcmpMessage begin
    base   :: IcmpCommon
    unused :: U32 = 0
end

"""
    IcmpEchoRequest(; identifier, sequence_number, base)

An echo request, 8 bytes — RFC 792's Echo.
"""
@header IcmpEchoRequest <: IcmpMessage begin
    base            :: IcmpCommon = IcmpCommon(type = ICMP_ECHO_REQUEST)
    identifier      :: U16
    sequence_number :: U16
end

"""
    IcmpEchoReply(; identifier, sequence_number, base)

An echo reply, 8 bytes.
"""
@header IcmpEchoReply <: IcmpMessage begin
    base            :: IcmpCommon = IcmpCommon(type = ICMP_ECHO_REPLY)
    identifier      :: U16
    sequence_number :: U16
end

"""
    IcmpPtb(; mtu, base)

Destination Unreachable with the Fragmentation Needed code — RFC 1191's Path
MTU Discovery message, 8 bytes.
"""
@header IcmpPtb <: IcmpMessage begin
    base   :: IcmpCommon = IcmpCommon(type = ICMP_DESTINATION_UNREACHABLE,
                                      code = ICMP_DU_FRAGMENTATION_NEEDED)
    unused :: U16        = 0
    mtu    :: U16
end

list_variants(::Type{IcmpMessage}) = (IcmpEchoRequest, IcmpEchoReply, IcmpPtb)
variant_base(::Type{IcmpMessage}) = IcmpCommon
variant_fallback(::Type{IcmpMessage}) = IcmpHeader

matches_variant(::Type{IcmpEchoRequest}, base) = base.type == ICMP_ECHO_REQUEST
matches_variant(::Type{IcmpEchoReply}, base)   = base.type == ICMP_ECHO_REPLY
matches_variant(::Type{IcmpPtb}, base) =
    base.type == ICMP_DESTINATION_UNREACHABLE && base.code == ICMP_DU_FRAGMENTATION_NEEDED
