# ============================================================================
# EthernetCsmaMac — the 6-state MAC.
#
# The machine itself is NOT written here. It is a state machine document, and
# `MacFsm.jl` beside this file is generated from it:
#
#     tool/generate_mac_fsm.jl        the machine (states, transitions, the
#                                     code around them)
#     t1s/MacFsm.jl                   generated — do not edit
#
# What is left here is the one piece the generator cannot express: a
# constructor with keyword arguments. The julia domain models keyword
# arguments in a *call* but not in a function *definition*, so this stays
# hand-written until it does.
#
# States, faithful to EthernetCsmaMac.cc:184-314 and numbered as the enum this
# replaces was (the values reach the .vec output and the network hash):
#   MAC_S_IDLE          0   nothing pending
#   MAC_S_WAIT_IFG      1   just finished tx/rx; waiting IFG (9.6 µs)
#   MAC_S_TRANSMITTING  2   handing frame to PLCA, tx_timer running
#   MAC_S_JAMMING       3   collision detected; jam signal running (3.2 µs)
#   MAC_S_BACKOFF       4   after JAM; waiting slot before retry
#   MAC_S_RECEIVING     5   carrier is up (peer is transmitting)
#
# Under PLCA-only operation, JAMMING/BACKOFF fire ONLY when PLCA's DS_COLLIDE
# raises SIGNAL_ERROR (Phase 7). They're dormant in Phase 6.
# ============================================================================

# The interface structs come before the include: the generated host struct
# annotates fields with them, so they must already exist, while everything the
# generator emits after the struct dispatches on it.

"Downward interface — the PLCA layer."
struct MacDownlink
    start_frame_tx   :: Function     # (ctx, packet, esd_ignored)
    end_frame_tx     :: Function     # (ctx)
    start_signal_tx  :: Function     # (ctx, kind::EthernetSignalKind)  # JAM
    end_signal_tx    :: Function     # (ctx)
end

_mac_no_downlink(_...) = nothing
const NO_MAC_DOWNLINK = MacDownlink(_mac_no_downlink, _mac_no_downlink,
                                    _mac_no_downlink, _mac_no_downlink)

"Upward interface — the app / queue above."
struct MacUpcalls
    frame_received :: Function       # (ctx, mac, packet)
    frame_sent     :: Function       # (ctx, mac)
end

_mac_no_upcall(_...) = nothing
const NO_MAC_UPCALLS = MacUpcalls(_mac_no_upcall, _mac_no_upcall)

include("MacFsm.jl")

"""
    MacState(module_id, address; bitrate, seed, promiscuous, downlink, upcalls)

Build a MAC. The generated struct's field order is machines, then timers, then
variables, so every field is passed explicitly here rather than positionally
by accident.

The machine's transition hook is wired to the statistics emitter, which is how
a state change reaches the `.vec` output — the recording is attached to the
machine, not tangled into the transition logic.
"""
function MacState(module_id::Int, address::UInt64;
                  bitrate::Float64 = 10.0e6,
                  seed::Integer = Int(address),
                  promiscuous::Bool = false,
                  downlink::MacDownlink = NO_MAC_DOWNLINK,
                  upcalls::MacUpcalls = NO_MAC_UPCALLS)
    mac = MacState(Fsm(:Mac, MAC_S_IDLE),
                   TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(),
                   module_id, nothing, Packet[], 0, false, false,
                   MersenneTwister(seed), bitrate, address, promiscuous,
                   downlink, upcalls, ETHERNET_PHY_ESD_LEN_BYTES * 8,
                   nothing, 0, Dict{Symbol,Int}(), 0, 0)
    mac.fsm_mac.on_transition = (fsm, from, to, index) -> _mac_on_transition(mac, from, to)
    mac
end
