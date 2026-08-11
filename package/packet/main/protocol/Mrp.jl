# ============================================================================
# The media redundancy protocol — IEC 62439-2.
#
# A ring of bridges keeps one link blocked so that the ring is a line. The
# manager tests the ring with a frame that must come back to it, and when one
# does not return the manager unblocks the link. These are the frames that say
# so.
#
# A protocol data unit is a version field and then a list of type-length-value
# records, ended by the End record. That is the option family shape, so the
# records are one, and `Options{MrpTlv}` reads them.
#
# Every record but End is padded to a multiple of four octets. The padding is
# measured from the start of the record, not from the start of the frame, which
# is why an option that begins at an odd offset still pads correctly: a member
# deserialized on its own starts at zero.
#
# `MrpLinkChange` in INET carries either the Link Down or the Link Up type in
# one class. They are two record types with one layout, so they are two members
# here, and each states its own code. The same is true of the two test
# sub-records.
# ============================================================================

const MRP_TLV_END                 = 0x00
const MRP_TLV_COMMON              = 0x01
const MRP_TLV_TEST                = 0x02
const MRP_TLV_TOPOLOGY_CHANGE     = 0x03
const MRP_TLV_LINK_DOWN           = 0x04
const MRP_TLV_LINK_UP             = 0x05
const MRP_TLV_IN_TEST             = 0x06
const MRP_TLV_IN_TOPOLOGY_CHANGE  = 0x07
const MRP_TLV_IN_LINK_DOWN        = 0x08
const MRP_TLV_IN_LINK_UP          = 0x09
const MRP_TLV_IN_LINK_STATUS_POLL = 0x0a
const MRP_TLV_OPTION              = 0x7f

const MRP_SUBTLV_RESERVED           = 0x00
const MRP_SUBTLV_TEST_MANAGER_NACK  = 0x01
const MRP_SUBTLV_TEST_PROPAGATE     = 0x02
const MRP_SUBTLV_AUTO_MANAGER       = 0x03

"The organizationally unique identifiers an Option record carries."
const MRP_OUI_DEFAULT = 0x000000
const MRP_OUI_IEC     = 0x00154e

"The default frame priority a manager sends — IEC 62439-2."
const MRP_PRIORITY_DEFAULT = 0x8000

"""
    MrpVersion(; version)

The two octets at the front of every MRP frame, before the records.
"""
@header MrpVersion begin
    version :: U16 = 1
end

"The MRP records — one shape, and the type octet says which."
abstract type MrpTlv <: Fields end

"""
    MrpEnd()

The End record, two octets. It is the only record with no padding, because it
is the last thing in the frame.
"""
@header MrpEnd <: MrpTlv begin
    type         :: Constant{U8, MRP_TLV_END}
    value_length :: Constant{U8, 0}
end

"""
    MrpCommon(; sequence_id, domain_uuid_high, domain_uuid_low)

The Common record, twenty octets. Every frame carries one, and its domain
identifier is what keeps two rings on one link apart.
"""
@header MrpCommon <: MrpTlv begin
    type             :: Constant{U8, MRP_TLV_COMMON}
    value_length     :: Constant{U8, 18}
    sequence_id      :: U16 = 0
    domain_uuid_high :: U64 = 0
    domain_uuid_low  :: U64 = 0
    padding          :: Pad{Bytes(4), 0x00}
end

"""
    MrpTest(; source, port_role, ring_state, transition, timestamp, priority)

The Test record, twenty octets. The manager sends it both ways around the ring
and expects it back.
"""
@header MrpTest <: MrpTlv begin
    type         :: Constant{U8, MRP_TLV_TEST}
    value_length :: Constant{U8, 18}
    priority     :: U16 = MRP_PRIORITY_DEFAULT
    source       :: MacAddress
    port_role    :: U16 = 0
    ring_state   :: U16 = 0
    transition   :: U16 = 0
    timestamp    :: U32 = 0
    padding      :: Pad{Bytes(4), 0x00}
end

"""
    MrpTopologyChange(; source, interval, priority)

The Topology Change record, twelve octets. It tells the clients to forget what
they learned, because the ring has changed shape.
"""
@header MrpTopologyChange <: MrpTlv begin
    type         :: Constant{U8, MRP_TLV_TOPOLOGY_CHANGE}
    value_length :: Constant{U8, 10}
    priority     :: U16 = MRP_PRIORITY_DEFAULT
    source       :: MacAddress
    interval     :: U16 = 0
    padding      :: Pad{Bytes(4), 0x00}
end

"""
    MrpLinkDown(; source, interval, blocked)

The Link Down record, twelve octets. A client sends it when its ring port goes
down.
"""
@header MrpLinkDown <: MrpTlv begin
    type         :: Constant{U8, MRP_TLV_LINK_DOWN}
    value_length :: Constant{U8, 10}
    source       :: MacAddress
    interval     :: U16 = 0
    blocked      :: U16 = 0
    padding      :: Pad{Bytes(4), 0x00}
end

"""
    MrpLinkUp(; source, interval, blocked)

The Link Up record, twelve octets. It has the layout of Link Down and its own
type octet.
"""
@header MrpLinkUp <: MrpTlv begin
    type         :: Constant{U8, MRP_TLV_LINK_UP}
    value_length :: Constant{U8, 10}
    source       :: MacAddress
    interval     :: U16 = 0
    blocked      :: U16 = 0
    padding      :: Pad{Bytes(4), 0x00}
end

"""
    MrpInTest(; source, port_role, interconnection_state, transition, timestamp)

The Interconnection Test record, twenty octets. An interconnection joins two
rings, and this tests it as the Test record tests a ring.
"""
@header MrpInTest <: MrpTlv begin
    type                  :: Constant{U8, MRP_TLV_IN_TEST}
    value_length          :: Constant{U8, 18}
    interconnection_id    :: U16 = MRP_PRIORITY_DEFAULT
    source                :: MacAddress
    port_role             :: U16 = 0
    interconnection_state :: U16 = 0
    transition            :: U16 = 0
    timestamp             :: U32 = 0
    padding               :: Pad{Bytes(4), 0x00}
end

"""
    MrpInTopologyChange(; source, interconnection_id, interval)

The Interconnection Topology Change record, twelve octets.
"""
@header MrpInTopologyChange <: MrpTlv begin
    type               :: Constant{U8, MRP_TLV_IN_TOPOLOGY_CHANGE}
    value_length       :: Constant{U8, 10}
    source             :: MacAddress
    interconnection_id :: U16 = 0
    interval           :: U16 = 0
    padding            :: Pad{Bytes(4), 0x00}
end

"""
    MrpInLinkDown(; source, port_role, interconnection_id, interval, link_info)

The Interconnection Link Down record, sixteen octets. `link_info` says why the
link went down.
"""
@header MrpInLinkDown <: MrpTlv begin
    type               :: Constant{U8, MRP_TLV_IN_LINK_DOWN}
    value_length       :: Constant{U8, 14}
    source             :: MacAddress
    port_role          :: U16 = 0
    interconnection_id :: U16 = 0
    interval           :: U16 = 0
    link_info          :: U16 = 0
    padding            :: Pad{Bytes(4), 0x00}
end

"""
    MrpInLinkUp(; source, port_role, interconnection_id, interval, link_info)

The Interconnection Link Up record, sixteen octets.
"""
@header MrpInLinkUp <: MrpTlv begin
    type               :: Constant{U8, MRP_TLV_IN_LINK_UP}
    value_length       :: Constant{U8, 14}
    source             :: MacAddress
    port_role          :: U16 = 0
    interconnection_id :: U16 = 0
    interval           :: U16 = 0
    link_info          :: U16 = 0
    padding            :: Pad{Bytes(4), 0x00}
end

"""
    MrpInLinkStatusPoll(; source, port_role, interconnection_id)

The Interconnection Link Status Poll record, twelve octets. It asks the other
end of an interconnection to say what state its link is in.
"""
@header MrpInLinkStatusPoll <: MrpTlv begin
    type               :: Constant{U8, MRP_TLV_IN_LINK_STATUS_POLL}
    value_length       :: Constant{U8, 10}
    source             :: MacAddress
    port_role          :: U16 = 0
    interconnection_id :: U16 = 0
    padding            :: Pad{Bytes(4), 0x00}
end

"""
    MrpOption(; organization, edition1_type)

The Option record, eight octets. Six carry the record, and two are the padding
that takes it to a multiple of four.
"""
@header MrpOption <: MrpTlv begin
    type          :: Constant{U8, MRP_TLV_OPTION}
    value_length  :: Constant{U8, 4}
    organization  :: U24 = MRP_OUI_IEC
    edition1_type :: U8  = 0xff
    padding       :: Pad{Bytes(4), 0x00}
end

list_options(::Type{MrpTlv}) =
    (MrpEnd, MrpCommon, MrpTest, MrpTopologyChange, MrpLinkDown, MrpLinkUp,
     MrpInTest, MrpInTopologyChange, MrpInLinkDown, MrpInLinkUp,
     MrpInLinkStatusPoll, MrpOption)
find_raw_option(::Type{MrpTlv}) = MrpEnd
ends_option_list(::Type{MrpTlv}, code) = code == MRP_TLV_END

# ---------- the sub-records an Option carries --------------------------------

"The MRP sub-records — one shape, and the sub-type octet says which."
abstract type MrpSubTlv <: Fields end

"""
    MrpAutoManager()

The Automatic Manager sub-record, two octets.
"""
@header MrpAutoManager <: MrpSubTlv begin
    sub_type   :: Constant{U8, MRP_SUBTLV_AUTO_MANAGER}
    sub_length :: Constant{U8, 0}
end

"""
    MrpManufacturerFunction()

A manufacturer's own sub-record, two octets.
"""
@header MrpManufacturerFunction <: MrpSubTlv begin
    sub_type   :: Constant{U8, MRP_SUBTLV_RESERVED}
    sub_length :: Constant{U8, 0}
end

"""
    MrpSubTlvTestPropagate(; source, priority, other_manager_source, other_manager_priority)

The Test Propagate sub-record, eighteen octets. A manager that yields to
another one propagates which manager won.
"""
@header MrpSubTlvTestPropagate <: MrpSubTlv begin
    sub_type               :: Constant{U8, MRP_SUBTLV_TEST_PROPAGATE}
    sub_length             :: Constant{U8, 16}
    priority               :: U16 = MRP_PRIORITY_DEFAULT
    source                 :: MacAddress
    other_manager_priority :: U16 = 0
    other_manager_source   :: MacAddress
end

"""
    MrpSubTlvTestManagerNack(; source, priority, other_manager_source, other_manager_priority)

The Test Manager Negative Acknowledgement sub-record, eighteen octets. It has
the layout of Test Propagate and its own sub-type octet.
"""
@header MrpSubTlvTestManagerNack <: MrpSubTlv begin
    sub_type               :: Constant{U8, MRP_SUBTLV_TEST_MANAGER_NACK}
    sub_length             :: Constant{U8, 16}
    priority               :: U16 = MRP_PRIORITY_DEFAULT
    source                 :: MacAddress
    other_manager_priority :: U16 = 0
    other_manager_source   :: MacAddress
end

list_options(::Type{MrpSubTlv}) =
    (MrpAutoManager, MrpManufacturerFunction, MrpSubTlvTestPropagate,
     MrpSubTlvTestManagerNack)
find_raw_option(::Type{MrpSubTlv}) = MrpManufacturerFunction
