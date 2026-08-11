# ============================================================================
# Protocol independent multicast — RFC 7761 for sparse mode and RFC 3973 for
# dense mode.
#
# Every message starts with the same four octets and the type nibble says which
# one this is. What follows is built from three encoded address forms that RFC
# 7761 clause 4.9.1 defines once and every message reuses, so each is a header
# of its own here.
#
# A Graft and a Graft Acknowledgement carry the same body as a Join/Prune, and
# they are declared that way. INET writes a Graft with no body at all when its
# chunk length says four octets; RFC 3973 clause 4.6 gives it the Join/Prune
# body, and a receiver that gets four octets has nothing to act on.
# ============================================================================

const PIM_HELLO          = 0
const PIM_REGISTER       = 1
const PIM_REGISTER_STOP  = 2
const PIM_JOIN_PRUNE     = 3
const PIM_BOOTSTRAP      = 4
const PIM_ASSERT         = 5
const PIM_GRAFT          = 6
const PIM_GRAFT_ACK      = 7
const PIM_CANDIDATE_RP   = 8
const PIM_STATE_REFRESH  = 9

"The Hello options — RFC 7761 clause 4.9.2."
const PIM_OPTION_HOLD_TIME       = 1
const PIM_OPTION_LAN_PRUNE_DELAY = 2
const PIM_OPTION_DR_PRIORITY     = 19
const PIM_OPTION_GENERATION_ID   = 20

"The address families and encodings of an encoded address — clause 4.9.1."
const PIM_ADDRESS_FAMILY_INET = 1
const PIM_ENCODING_NATIVE     = 0

"""
    PimUnicastAddress(; address)

An encoded unicast address, six octets — RFC 7761 clause 4.9.1.
"""
@header PimUnicastAddress begin
    address_family :: U8 = PIM_ADDRESS_FAMILY_INET
    encoding_type  :: U8 = PIM_ENCODING_NATIVE
    address        :: Ipv4Address
end

"""
    PimGroupAddress(; address, mask_length, bidirectional, zone_scoped)

An encoded group address, eight octets — RFC 7761 clause 4.9.1. `bidirectional`
is the B bit and `zone_scoped` is the Z bit.
"""
@header PimGroupAddress begin
    address_family :: U8   = PIM_ADDRESS_FAMILY_INET
    encoding_type  :: U8   = PIM_ENCODING_NATIVE
    bidirectional  :: Bool = false
    reserved       :: U6   = 0
    zone_scoped    :: Bool = false
    mask_length    :: U8   = 32
    address        :: Ipv4Address
end

"""
    PimSourceAddress(; address, mask_length, sparse, wildcard, rendezvous_point)

An encoded source address, eight octets — RFC 7761 clause 4.9.1. `sparse` is
the S bit, `wildcard` the W bit and `rendezvous_point` the R bit.
"""
@header PimSourceAddress begin
    address_family   :: U8   = PIM_ADDRESS_FAMILY_INET
    encoding_type    :: U8   = PIM_ENCODING_NATIVE
    reserved         :: U5   = 0
    sparse           :: Bool = true
    wildcard         :: Bool = false
    rendezvous_point :: Bool = false
    mask_length      :: U8   = 32
    address          :: Ipv4Address
end

# ---------- the Hello options ------------------------------------------------

"The PIM Hello options — one shape, and the type says which."
abstract type PimOption <: Fields end

"""
    PimHoldTime(; hold_time)

The Hold Time option, six octets — RFC 7761 clause 4.9.2. It says how long a
neighbour should keep this router.
"""
@header PimHoldTime <: PimOption begin
    type      :: Constant{U16, PIM_OPTION_HOLD_TIME}
    length    :: Constant{U16, 2}
    hold_time :: U16 = 105
end

"""
    PimLanPruneDelay(; propagation_delay, override_interval, tracking)

The LAN Prune Delay option, eight octets — RFC 7761 clause 4.9.2. `tracking` is
the T bit, which INET writes as a zero and does not model.
"""
@header PimLanPruneDelay <: PimOption begin
    type              :: Constant{U16, PIM_OPTION_LAN_PRUNE_DELAY}
    length            :: Constant{U16, 4}
    tracking          :: Bool = false
    propagation_delay :: U15  = 0
    override_interval :: U16  = 0
end

"""
    PimDrPriority(; priority)

The Designated Router Priority option, eight octets — RFC 7761 clause 4.9.2.
"""
@header PimDrPriority <: PimOption begin
    type     :: Constant{U16, PIM_OPTION_DR_PRIORITY}
    length   :: Constant{U16, 4}
    priority :: U32 = 1
end

"""
    PimGenerationId(; generation_id)

The Generation Identifier option, eight octets — RFC 7761 clause 4.9.2. A new
value tells a neighbour that this router restarted.
"""
@header PimGenerationId <: PimOption begin
    type          :: Constant{U16, PIM_OPTION_GENERATION_ID}
    length        :: Constant{U16, 4}
    generation_id :: U32 = 0
end

"""
    PimOptionRaw(; type, data)

A Hello option this library does not model. It keeps its type and its octets.
"""
@header PimOptionRaw <: PimOption begin
    type   :: U16
    length :: U16 = 0
        derive(Base.length(data))
    data   :: Octets = UInt8[]
        length(Bytes(length))
end

list_options(::Type{PimOption}) =
    (PimHoldTime, PimLanPruneDelay, PimDrPriority, PimGenerationId)
find_raw_option(::Type{PimOption}) = PimOptionRaw
measure_option_code(::Type{PimOption}) = 16

# ---------- the messages -----------------------------------------------------

"The PIM messages — one wire format, and the type nibble says which."
abstract type PimPacket <: Fields end

"""
    PimCommon(; type, checksum)

The four octets every PIM message starts with — RFC 7761 clause 4.9.
"""
@header PimCommon <: PimPacket begin
    version       :: U4 = 2
    type          :: U4 = PIM_HELLO
    reserved      :: U8 = 0
    checksum      :: Checksum16 = 0
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    PimHello(; options)

A Hello message — RFC 7761 clause 4.9.2. Its options run to the end of the
message, so nothing counts them.
"""
@header PimHello <: PimPacket begin
    base    :: PimCommon = PimCommon(type = PIM_HELLO)
    options :: Options{PimOption} = PimOption[]
end

"""
    PimRegister(; border, null_register)

A Register message, eight octets before the datagram it carries — RFC 7761
clause 4.9.3. `null_register` is the N bit.
"""
@header PimRegister <: PimPacket begin
    base          :: PimCommon = PimCommon(type = PIM_REGISTER)
    border        :: Bool = false
    null_register :: Bool = false
    reserved2     :: U30  = 0
end

"""
    PimRegisterStop(; group, source)

A Register Stop message, eighteen octets — RFC 7761 clause 4.9.4.
"""
@header PimRegisterStop <: PimPacket begin
    base   :: PimCommon = PimCommon(type = PIM_REGISTER_STOP)
    group  :: PimGroupAddress
    source :: PimUnicastAddress
end

"""
    PimJoinPruneGroup(; group, joined_sources, pruned_sources)

One group of a Join/Prune message — RFC 7761 clause 4.9.5. No two groups are
the same width, because each carries source lists of its own.
"""
@header PimJoinPruneGroup begin
    group         :: PimGroupAddress
    joined_count  :: U16 = 0
        derive(Base.length(joined_sources))
    pruned_count  :: U16 = 0
        derive(Base.length(pruned_sources))
    joined_sources :: Repeated{PimSourceAddress} = PimSourceAddress[]
        count(joined_count)
    pruned_sources :: Repeated{PimSourceAddress} = PimSourceAddress[]
        count(pruned_count)
end

"""
    PimJoinPrune(; upstream_neighbor, groups, hold_time)

A Join/Prune message — RFC 7761 clause 4.9.5. The groups fill the message, and
`group_count` is what the writer derives from them.
"""
@header PimJoinPrune <: PimPacket begin
    base              :: PimCommon = PimCommon(type = PIM_JOIN_PRUNE)
    upstream_neighbor :: PimUnicastAddress
    reserved2         :: U8  = 0
    group_count       :: U8  = 0
        derive(Base.length(groups))
    hold_time         :: U16 = 210
    groups            :: Repeated{PimJoinPruneGroup} = PimJoinPruneGroup[]
end

"""
    PimGraft(; upstream_neighbor, groups)

A Graft message — RFC 3973 clause 4.6. It has the Join/Prune body, and its hold
time is always zero.
"""
@header PimGraft <: PimPacket begin
    base              :: PimCommon = PimCommon(type = PIM_GRAFT)
    upstream_neighbor :: PimUnicastAddress
    reserved2         :: U8  = 0
    group_count       :: U8  = 0
        derive(Base.length(groups))
    hold_time         :: U16 = 0
    groups            :: Repeated{PimJoinPruneGroup} = PimJoinPruneGroup[]
end

"""
    PimGraftAck(; upstream_neighbor, groups)

A Graft Acknowledgement — RFC 3973 clause 4.7. It echoes the Graft it answers.
"""
@header PimGraftAck <: PimPacket begin
    base              :: PimCommon = PimCommon(type = PIM_GRAFT_ACK)
    upstream_neighbor :: PimUnicastAddress
    reserved2         :: U8  = 0
    group_count       :: U8  = 0
        derive(Base.length(groups))
    hold_time         :: U16 = 0
    groups            :: Repeated{PimJoinPruneGroup} = PimJoinPruneGroup[]
end

"""
    PimAssert(; group, source, metric_preference, metric)

An Assert message, twenty-six octets — RFC 7761 clause 4.9.6. Two routers that
both forward to the same link send it, and the better metric wins.
"""
@header PimAssert <: PimPacket begin
    base              :: PimCommon = PimCommon(type = PIM_ASSERT)
    group             :: PimGroupAddress
    source            :: PimUnicastAddress
    rendezvous_tree   :: Bool = false
    metric_preference :: U31  = 0
    metric            :: U32  = 0
end

"""
    PimStateRefresh(; group, source, originator, interval, …)

A State Refresh message, thirty-six octets — RFC 3973 clause 4.5. Dense mode
sends it so that pruned branches stay pruned without timing out.
"""
@header PimStateRefresh <: PimPacket begin
    base              :: PimCommon = PimCommon(type = PIM_STATE_REFRESH)
    group             :: PimGroupAddress
    source            :: PimUnicastAddress
    originator        :: PimUnicastAddress
    rendezvous_tree   :: Bool = false
    metric_preference :: U31  = 0
    metric            :: U32  = 0
    mask_length       :: U8   = 32
    time_to_live      :: U8   = 0
    prune_indicator   :: Bool = false
    prune_now         :: Bool = false
    assert_override   :: Bool = false
    reserved2         :: U5   = 0
    interval          :: U8   = 0
end

list_variants(::Type{PimPacket}) =
    (PimHello, PimRegister, PimRegisterStop, PimJoinPrune, PimAssert,
     PimGraft, PimGraftAck, PimStateRefresh)
variant_base(::Type{PimPacket}) = PimCommon

matches_variant(::Type{PimHello}, base)         = base.type == PIM_HELLO
matches_variant(::Type{PimRegister}, base)      = base.type == PIM_REGISTER
matches_variant(::Type{PimRegisterStop}, base)  = base.type == PIM_REGISTER_STOP
matches_variant(::Type{PimJoinPrune}, base)     = base.type == PIM_JOIN_PRUNE
matches_variant(::Type{PimAssert}, base)        = base.type == PIM_ASSERT
matches_variant(::Type{PimGraft}, base)         = base.type == PIM_GRAFT
matches_variant(::Type{PimGraftAck}, base)      = base.type == PIM_GRAFT_ACK
matches_variant(::Type{PimStateRefresh}, base)  = base.type == PIM_STATE_REFRESH
