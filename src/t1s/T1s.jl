# ============================================================================
# The `T1s` module — INET's 10BASE-T1S + PLCA multidrop model, on the Omnetpp
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

using ..PacketModule
using Omnetpp: SimTime, to_simtime, schedule!, schedule_root!, ScheduleContext,
               MersenneTwister,
               emit_indexed_vector!, record_scalar!, TIME_UNIT

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
    PlcaControlState, CS_DISABLE, CS_RESYNC, CS_RECOVER, CS_SEND_BEACON,
    CS_SYNCING, CS_WAIT_TO, CS_EARLY_RECEIVE, CS_COMMIT, CS_YIELD,
    CS_RECEIVE, CS_TRANSMIT, CS_BURST, CS_ABORT, CS_NEXT_TX_OPPORTUNITY,
    PlcaCmd, CMD_NONE, CMD_BEACON, CMD_COMMIT,
    PlcaConfig, PlcaState,
    PlcaControlUpcalls, PlcaDownlink, NO_PLCA_UPCALLS, NO_PLCA_DOWNLINK,
    plca_start!, handle_with_control_fsm!,
    plca_on_carrier_sense_start!, plca_on_carrier_sense_end!,
    plca_on_reception_start!, plca_on_reception_end!,
    plca_on_collision_start!, plca_on_collision_end!,
    # PLCA data
    PlcaDataState, DS_IDLE, DS_WAIT_IDLE, DS_RECEIVE, DS_HOLD, DS_TRANSMIT,
    DS_COLLIDE, DS_DELAY_PENDING, DS_PENDING, DS_WAIT_MAC,
    PlcaDataFsm, plca_data,
    plca_start_frame_transmission!, plca_end_frame_transmission!,
    plca_start_signal_from_mac!, plca_end_signal_from_mac!,
    plca_commit_to!,
    plca_data_on_reception_start!, plca_data_on_reception_end!,
    default_plca_upcalls,
    # MAC
    MacFsmState, MAC_IDLE, MAC_WAIT_IFG, MAC_TRANSMITTING, MAC_JAMMING,
    MAC_BACKOFF, MAC_RECEIVING,
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
include("PlcaData.jl")
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
