# ============================================================================
# The bridge protocol data units — IEEE 802.1D, clause 9.
#
# A bridge sends two of them. A Configuration BPDU carries the spanning tree
# it believes in, and a Topology Change Notification says only that something
# moved. They share the first four octets, and the type octet says which.
#
# Every time in a BPDU is in 256ths of a second, so a hello time of two seconds
# is 512 on the wire. `measure_bpdu_seconds` reads one back.
#
# INET writes the four bits between the agreement flag and the proposal flag as
# reserved. IEEE 802.1D-2004 figure 9-4 names them: they are the forwarding
# bit, the learning bit and the two port role bits that rapid spanning tree
# added. They are declared here, and a bridge that leaves them zero writes the
# same octet INET does.
# ============================================================================

const BPDU_PROTOCOL_SPANNING_TREE = 0

const BPDU_VERSION_SPANNING_TREE          = 0
const BPDU_VERSION_RAPID_SPANNING_TREE    = 2
const BPDU_VERSION_MULTIPLE_SPANNING_TREE = 3

const BPDU_CONFIGURATION                = 0x00
const BPDU_TOPOLOGY_CHANGE_NOTIFICATION = 0x80

"The port roles of rapid spanning tree — IEEE 802.1D-2004 table 9-1."
const BPDU_PORT_ROLE_UNKNOWN     = 0
const BPDU_PORT_ROLE_ALTERNATE   = 1
const BPDU_PORT_ROLE_ROOT        = 2
const BPDU_PORT_ROLE_DESIGNATED  = 3

"The bridge protocol data units — one wire format, and the type says which."
abstract type Bpdu <: Fields end

"""
    BpduCommon(; type, protocol_version)

The four octets every BPDU starts with — IEEE 802.1D clause 9.3.1. A Topology
Change Notification is these four octets and nothing else, so this is both the
discriminator and a complete BPDU.
"""
@header BpduCommon <: Bpdu begin
    protocol_identifier :: U16 = BPDU_PROTOCOL_SPANNING_TREE
    protocol_version    :: U8  = BPDU_VERSION_SPANNING_TREE
    type                :: U8  = BPDU_CONFIGURATION
end

"""
    BpduTopologyChangeNotification()

A Topology Change Notification BPDU, four octets — IEEE 802.1D clause 9.3.2. A
bridge sends it towards the root when it sees the topology change.
"""
@header BpduTopologyChangeNotification <: Bpdu begin
    base :: BpduCommon = BpduCommon(type = BPDU_TOPOLOGY_CHANGE_NOTIFICATION)
end

"""
    BpduConfiguration(; root_priority, root_address, root_path_cost, …)

A Configuration BPDU, thirty-five octets — IEEE 802.1D clause 9.3.1.

A bridge identifier is a priority and an address, which is why the root and the
sender each take two fields. The four timers are in 256ths of a second.
"""
@header BpduConfiguration <: Bpdu begin
    base                :: BpduCommon = BpduCommon(type = BPDU_CONFIGURATION)
    topology_change_ack :: Bool = false
    agreement           :: Bool = false
    forwarding          :: Bool = false
    learning            :: Bool = false
    port_role           :: U2   = BPDU_PORT_ROLE_UNKNOWN
    proposal            :: Bool = false
    topology_change     :: Bool = false
    root_priority       :: U16
    root_address        :: MacAddress
    root_path_cost      :: U32  = 0
    bridge_priority     :: U16
    bridge_address      :: MacAddress
    port_priority       :: U8   = 0
    port_number         :: U8   = 0
    message_age         :: U16  = 0
    max_age             :: U16
    hello_time          :: U16
    forward_delay       :: U16
end

"A BPDU timer in seconds — the field counts 256ths of a second."
measure_bpdu_seconds(ticks::Integer) = Int(ticks) / 256

"The field value a timer of `seconds` needs."
build_bpdu_ticks(seconds::Real) = U16(round(Int, seconds * 256))

list_variants(::Type{Bpdu}) = (BpduConfiguration, BpduTopologyChangeNotification)
variant_base(::Type{Bpdu}) = BpduCommon

matches_variant(::Type{BpduConfiguration}, base) = base.type == BPDU_CONFIGURATION
matches_variant(::Type{BpduTopologyChangeNotification}, base) =
    base.type == BPDU_TOPOLOGY_CHANGE_NOTIFICATION
