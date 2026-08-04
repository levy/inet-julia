"""
    InetPacketExample

Runnable demonstrations of `InetPacket`. Each demo is a function, so it is
discoverable, callable with keywords, and returns what it built:

    using InetPacketExample
    demos()                 # [:packet_api]
    run_demo(:packet_api)   # or packet_api_demo() directly

`packet_api_demo` is a worked tour of the packet & chunk API — headers, tags,
duplication with a shared payload, the bytes-on-the-wire view, and what the R9
reinterpretation guard refuses.
"""
module InetPacketExample

using InetPacket.PacketModule

include(joinpath(@__DIR__, "packet_api_demo.jl"))

"""
    DEMOS :: Dict{Symbol, Function}

Every bundled demo, by name. `run_demo` dispatches through this and `demos()`
lists it, so adding a demo is one entry rather than a file someone has to know
to look for.
"""
const DEMOS = Dict{Symbol, Function}(
    :packet_api => packet_api_demo,
)

"""
    demos() -> Vector{Symbol}

The name of every bundled demo.
"""
demos() = sort!(collect(keys(DEMOS)))

"""
    run_demo(name::Symbol; kwargs...)

Run the named demo, forwarding `kwargs` to it — `run_demo(:packet_api)` is
`packet_api_demo()`.
"""
function run_demo(name::Symbol; kwargs...)
    haskey(DEMOS, name) ||
        error("unknown demo ", repr(name), "; available: ", join(demos(), ", "))
    DEMOS[name](; kwargs...)
end

export DEMOS, demos, run_demo
export packet_api_demo, make_packet, forward!, broadcast_packet
export Ipv4Header, RoutingRequest, CreationTimeTag, HopCountTag

end # module InetPacketExample
