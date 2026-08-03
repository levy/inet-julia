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

# ============================================================================
# TimerHandle — cancellation via a generation counter.
#
# The omnetpp-julia scheduler has no first-class event cancellation, but PLCA
# and MAC routinely need to cancel or reschedule timers. Pattern: each timer
# owns a mutable handle carrying a generation counter. Scheduling bumps the
# counter and captures the fresh value; the scheduled closure checks that its
# captured value still matches before firing. Cancel/reschedule = bump.
# ============================================================================

mutable struct TimerHandle
    gen::Int         # bumped on every schedule or cancel; stale callbacks no-op
    active::Bool     # true iff currently outstanding (INET's `isScheduled`)
end
TimerHandle() = TimerHandle(0, false)

is_scheduled(h::TimerHandle) = h.active
cancel!(h::TimerHandle) = (h.gen += 1; h.active = false; h)

"""
    schedule_timer!(ctx, delay, module_id, h::TimerHandle, action)

Schedule `action` to fire after `delay`, guarded by the timer handle. Any
prior outstanding scheduling on `h` is implicitly cancelled (their generation
is now stale). `action` is only called if `h` hasn't been cancelled or
re-scheduled since.
"""
function schedule_timer!(ctx, delay::SimTime, module_id::Int,
                         h::TimerHandle, action::Function)
    h.gen += 1
    h.active = true
    gen = h.gen
    # NOTE: schedule! wants (ctx, delay, module_id, action) with action LAST,
    # so we can't use do-block syntax here (it would pass the closure as arg 1).
    schedule!(ctx, delay, module_id, function (ctx2)
        h.gen == gen || return    # stale — cancelled or superseded
        h.active = false           # fired now
        action(ctx2)
    end)
end
