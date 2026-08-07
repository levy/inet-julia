"""
    InetPacketExample

Runnable demonstrations of `InetPacket`. Each demo is a function, so it is
discoverable, callable with keywords, and returns what it built:

    using InetPacketExample
    packet_demos()                 # [:packet_api]
    run_packet_demo(:packet_api)   # or packet_api_demo() directly

The names carry `packet` because these live in one namespace with every other
component's demos once `InetExample` re-exports them, and because plain
`run_demo()` opens the demo catalog.

`packet_api_demo` is a worked tour of the packet & chunk API — headers, tags,
duplication with a shared payload, the bytes-on-the-wire view, and what the R9
reinterpretation guard refuses.
"""
module InetPacketExample

using InetPacket.PacketModule

# `Ipv4Header` and `UdpHeader` come from `InetPacket` itself, declared in
# `packet/main/protocol/`. The demo builds packets out of the real headers, so
# what a catalog page embeds is the declaration the library runs on.
include(joinpath(@__DIR__, "packet_api_demo.jl"))

"""
    PACKET_DEMOS :: Dict{Symbol, Function}

Every bundled demo, by name. `run_packet_demo` dispatches through this and
`packet_demos()` lists it, so adding a demo is one entry rather than a file
someone has to know to look for.
"""
const PACKET_DEMOS = Dict{Symbol, Function}(
    :packet_api => packet_api_demo,
)

"""
    packet_demos() -> Vector{Symbol}

The name of every bundled demo.
"""
packet_demos() = sort!(collect(keys(PACKET_DEMOS)))

"""
    run_packet_demo(name::Symbol; kwargs...)

Run the named demo, forwarding `kwargs` to it — `run_packet_demo(:packet_api)`
is `packet_api_demo()`.
"""
function run_packet_demo(name::Symbol; kwargs...)
    haskey(PACKET_DEMOS, name) ||
        error("unknown demo ", repr(name), "; available: ", join(packet_demos(), ", "))
    PACKET_DEMOS[name](; kwargs...)
end

export PACKET_DEMOS, packet_demos, run_packet_demo
export packet_api_demo, make_packet, make_frame, forward!, broadcast_packet
export reinterpretation_guard, truncated_packet, strict_peek
export reassemble_out_of_order, straddling_pop
export Ipv4Header, UdpHeader, RoutingRequest, CreationTimeTag, HopCountTag

end # module InetPacketExample
