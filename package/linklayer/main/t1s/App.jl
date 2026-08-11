# ============================================================================
# App layer — EthernetSourceApp / EthernetSinkApp (§5.7 of the plan).
#
# Simplified from INET's NED wrappers (EthernetApp + ActivePacketSource +
# EthernetSocketIo). For the target scenarios (notraffic/bestcase/worstcase),
# a deterministic fixed-interval source is enough. Poisson / uniform IA are
# follow-ups (plan F2).
# ============================================================================

# Interval kinds — only :fixed used by the three targets; :uniform / :poisson
# for follow-ups.
@enum IntervalKind::UInt8 IA_FIXED IA_UNIFORM IA_POISSON

struct SourceConfig
    dst_address::UInt64
    packet_length_min::Int          # bytes (frame length before headers/pad)
    packet_length_max::Int
    interval_kind::IntervalKind
    interval_min::Float64           # seconds
    interval_max::Float64
    initial_offset::SimTime
    ethertype::EtherTypeOrLength
end

function SourceConfig(; dst_address::UInt64,
                       packet_length::Int = 46,
                       interval::Float64,
                       initial_offset::Float64 = 0.0,
                       ethertype::Union{Integer, EtherTypeOrLength} = ETHERTYPE_IPV4)
    SourceConfig(dst_address, packet_length, packet_length,
                 IA_FIXED, interval, interval,
                 to_simtime(initial_offset), EtherTypeOrLength(ethertype))
end

mutable struct AppState
    module_id::Int
    address::UInt64
    source::Union{Nothing, SourceConfig}
    rng::MersenneTwister
    # Sink counters
    packets_received::Int
    total_e2e_delay::SimTime
    # MAC to push to
    mac::Union{Nothing, MacState}
end

function AppState(module_id::Int, address::UInt64;
                  source::Union{Nothing, SourceConfig} = nothing,
                  seed::Integer = Int(address))
    AppState(module_id, address, source, MersenneTwister(seed),
             0, SimTime(0), nothing)
end

# ---------- source generation -----------------------------------------------

"""
    app_generate!(ctx, app::AppState)

Emit one frame and re-schedule the next generation. Called via
`schedule_root!(sim, initial_offset, app.module_id, app_generate!)` from
the model's `schedule_initial_events!`.
"""
function app_generate!(ctx, app::AppState)
    src = app.source
    src === nothing && return
    # Draw packet length.
    pk_len = src.packet_length_min == src.packet_length_max ?
             src.packet_length_min :
             rand(app.rng, src.packet_length_min:src.packet_length_max)
    payload = Filler(Bytes(pk_len); fill = 0x00)
    frame = build_ethernet_frame(app.address, src.dst_address,
                                 src.ethertype, payload)
    # Push into MAC's queue.
    if app.mac !== nothing
        mac_upper_packet!(ctx, app.mac, frame)
    end
    # Schedule next generation.
    ia = _draw_interval(app)
    schedule!(ctx, ia, app.module_id,
              ctx2 -> app_generate!(ctx2, app))
end

function _draw_interval(app::AppState)::SimTime
    src = app.source
    if src.interval_kind === IA_FIXED
        return to_simtime(src.interval_min)
    elseif src.interval_kind === IA_UNIFORM
        return to_simtime(src.interval_min +
                          (src.interval_max - src.interval_min) * rand(app.rng))
    else # IA_POISSON
        # -log(U) * mean, standard exponential.
        return to_simtime(-src.interval_min * log(1.0 - rand(app.rng)))
    end
end

# ---------- sink ------------------------------------------------------------

"""
    app_receive!(ctx, app, packet)

Called by MAC's frame_received upcall. Increments counters; if the packet
carries a creation-time tag (Phase 9 adds this via the tag API), update
end-to-end delay.
"""
function app_receive!(ctx, app::AppState, packet::Packet)
    app.packets_received += 1
    # e2e delay tag support — Phase 9 will add CreationTimeTag via the
    # packet tag API. For now the counter is enough.
end
