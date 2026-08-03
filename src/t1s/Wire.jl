# ============================================================================
# Wire — the on-wire signal representation (§4.3 of the plan).
#
# INET's `EthernetSignal` (a `cMessage` subclass) carries a packet plus a
# kind, an ESD (end-of-stream delimiter), and a duration. Here we make the
# signal an isbits `WireEvent` that travels as the argument to a scheduled
# callback. No `cMessage` machinery, no serialization overhead.
#
# `EthernetSignalKind` and `EthernetEsdKind` mirror INET's enums verbatim
# (see `physicallayer/wired/ethernet/EthernetSignal.msg`).
# ============================================================================

# Signal kinds — the "what is this on the wire" tag.
@enum EthernetSignalKind::UInt8 begin
    SIG_NONE   = 0
    SIG_BEACON = 1
    SIG_COMMIT = 2
    SIG_DATA   = 3
    SIG_JAM    = 4
end

# End-of-stream delimiter kinds.
# ESDBRS = "burst-request"; sent on all frames of a burst except the last one.
@enum EthernetEsdKind::Int8 begin
    ESD_NONE = -1
    ESD_ESD  = 0
    ESD_BRS  = 1
    ESD_OK   = 2
    ESD_ERR  = 3
    ESD_JAB  = 4
end

# The on-wire event. isbits (three enums + one Packet ref + two ints + a bool).
struct WireEvent
    kind::EthernetSignalKind
    packet::Union{Nothing, Packet}      # nothing for BEACON / COMMIT
    esd::EthernetEsdKind                 # trailing ESD (post-data delimiter)
    duration::SimTime                    # total transmission time on wire
    src_module_id::Int                   # for filtering / diagnostics
    bit_error::Bool                      # true iff truncated / corrupted
end

# Convenience constructors matching INET's usage.
WireEvent(kind::EthernetSignalKind, duration::SimTime, src::Int) =
    WireEvent(kind, nothing, ESD_NONE, duration, src, false)

WireEvent(kind::EthernetSignalKind, pkt::Packet, esd::EthernetEsdKind,
          duration::SimTime, src::Int) =
    WireEvent(kind, pkt, esd, duration, src, false)

