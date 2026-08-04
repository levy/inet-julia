# ============================================================================
# The `T1s` module — INET's 10BASE-T1S + PLCA multidrop model, on the OmnetppSimulator
# discrete-event kernel.
# Design: plan/done/ten-base-t1s-plca.md.
#
# Layered, faithful to INET:
#   EthernetFrame.jl     Ethernet MAC header + FCS chunks (Phase 1)
#   Wire.jl              WireEvent, EthernetSignalKind/Esd enums (Phase 2)
#   Phy.jl               EthernetCsmaPhy 5-state FSM (Phase 2)
#   Junction.jl          WireJunction — T-junction node (Phase 3)
#   PlcaControl.jl       PLCA control FSM (14 states, Phase 4)
#   PlcaData.jl          PLCA data FSM (9 states, Phase 5+7)
#   Mac.jl               EthernetCsmaMac 6-state FSM (Phase 6)
#   App.jl               Source/sink/queue (Phase 8)
#   T1sModel.jl          AbstractModel wrapper + topology (Phase 9)
# ============================================================================

module T1sModule

using InetPacket.PacketModule
using OmnetppSimulator: SimTime, to_simtime, schedule!, schedule_root!, ScheduleContext,
               MersenneTwister,
               emit_indexed_vector!, record_scalar!, seconds
# Cancellable timers are a kernel utility rather than a 10BASE-T1S one; they are
# re-exported below so this module's names stay in a single list.
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, cancel!, schedule_timer!
# The MAC's transition logic is generated (see `Mac.jl`); this is the runtime
# it dispatches on.
using OmnetppSimulator.FsmModule: Fsm, fsm_state, fsm_enter!, fsm_leave!, fsm_goto!,
               fsm_defer!, fsm_drain!, fsm_cascade_error, fsm_unhandled_error,
               FSM_CASCADE_LIMIT

export
    # Ethernet frame chunks + helpers
    EthernetMacHeader, EthernetFcs, build_ethernet_frame,
    mac_pack, mac_hi, mac_lo,
    ETHERTYPE_IPV4, ETHERTYPE_ARP,
    MIN_ETHERNET_FRAME_BYTES, MAX_ETHERNET_FRAME_BYTES,
    INTERFRAME_GAP_BITS, JAM_SIGNAL_BYTES,
    ETHERNET_PHY_HEADER_LEN_BYTES, ETHERNET_PHY_ESD_LEN_BYTES,
    ETHERNET_TXRATE_10MB,
    # Wire
    EthernetSignalKind, SIG_NONE, SIG_BEACON, SIG_COMMIT, SIG_DATA, SIG_JAM,
    EthernetEsdKind, ESD_NONE, ESD_ESD, ESD_BRS, ESD_OK, ESD_ERR, ESD_JAB,
    WireEvent,
    TimerHandle, is_scheduled, cancel!, schedule_timer!,
    # PHY
    PhyFsmState, PHY_IDLE, PHY_TRANSMITTING, PHY_RECEIVING, PHY_COLLISION, PHY_CRS_ON,
    PhyState, PhyUpcalls, PhyDownlink, NO_UPCALLS, NO_DOWNLINK, recording_upcalls,
    phy_start_frame_transmission!, phy_start_signal_transmission!,
    phy_end_frame_transmission!, phy_end_signal_transmission!,
    phy_rx_start!, phy_rx_update!,
    RxSignal,
    # Junction
    JunctionPort, WireJunctionState, junction_add_port!,
    junction_receive!, junction_update!,
    # PLCA control
    CONTROL_S_DISABLE, CONTROL_S_RESYNC, CONTROL_S_RECOVER, CONTROL_S_SEND_BEACON,
    CONTROL_S_SYNCING, CONTROL_S_WAIT_TO, CONTROL_S_EARLY_RECEIVE, CONTROL_S_COMMIT,
    CONTROL_S_YIELD, CONTROL_S_RECEIVE, CONTROL_S_TRANSMIT, CONTROL_S_BURST,
    CONTROL_S_ABORT, CONTROL_S_NEXT_TX_OPPORTUNITY, CONTROL_STATE_NAMES,
    control_dispatch!,
    PlcaCmd, CMD_NONE, CMD_BEACON, CMD_COMMIT,
    PlcaConfig, PlcaState,
    PlcaControlUpcalls, PlcaDownlink, NO_PLCA_UPCALLS, NO_PLCA_DOWNLINK,
    plca_start!, handle_with_control_fsm!,
    plca_on_carrier_sense_start!, plca_on_carrier_sense_end!,
    plca_on_reception_start!, plca_on_reception_end!,
    plca_on_collision_start!, plca_on_collision_end!,
    # PLCA data
    DATA_S_IDLE, DATA_S_WAIT_IDLE, DATA_S_RECEIVE, DATA_S_HOLD, DATA_S_TRANSMIT,
    DATA_S_COLLIDE, DATA_S_DELAY_PENDING, DATA_S_PENDING, DATA_S_WAIT_MAC,
    DATA_STATE_NAMES, data_dispatch!,
    plca_start_frame_transmission!, plca_end_frame_transmission!,
    plca_start_signal_from_mac!, plca_end_signal_from_mac!,
    plca_commit_to!,
    plca_data_on_reception_start!, plca_data_on_reception_end!,
    default_plca_upcalls,
    # MAC
    MAC_S_IDLE, MAC_S_WAIT_IFG, MAC_S_TRANSMITTING, MAC_S_JAMMING,
    MAC_S_BACKOFF, MAC_S_RECEIVING, MAC_STATE_NAMES, mac_dispatch!, fsm_state,
    MacState, MacDownlink, MacUpcalls, NO_MAC_DOWNLINK, NO_MAC_UPCALLS,
    mac_handle_carrier_sense_start!, mac_handle_carrier_sense_end!,
    mac_handle_collision_start!, mac_handle_collision_end!,
    mac_handle_reception_end!, mac_upper_packet!,
    MAX_ATTEMPTS, BACKOFF_RANGE_LIMIT, SLOT_BIT_LENGTH_10MB,
    # App
    IntervalKind, IA_FIXED, IA_UNIFORM, IA_POISSON,
    SourceConfig, AppState, app_generate!, app_receive!

include("EthernetFrame.jl")
include("Wire.jl")
include("Phy.jl")
include("Junction.jl")
include("PlcaControl.jl")
include("Mac.jl")
include("App.jl")

# ============================================================================
# Default upcalls — wires the control FSM's `commit_to` to the data FSM's
# `plca_commit_to!`. Declared here so both files above are loaded first.
# ============================================================================

"""
    default_plca_upcalls()

Return a `PlcaControlUpcalls` that routes `commit_to` to the standard
`plca_commit_to!` (data FSM). `on_carrier_sense_change` and
`on_signal_error_change` remain no-ops; Phase 6 (MAC) plugs those in.
"""
default_plca_upcalls() = PlcaControlUpcalls(
    (ctx, plca) -> plca_commit_to!(ctx, plca),
    (ctx, plca) -> nothing,
    (ctx, plca) -> nothing,
)

end # module
