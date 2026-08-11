# Packet & chunk API (plan/done/packet-chunk-api.md) — phased conformance
# suite; each phase adds a file.
#
#     julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'

using Test

@testset "packet & chunk API" begin
    include("phase1_chunks.jl")
    include("phase2_packet.jl")
    include("phase3_headers.jl")
    include("phase4_quality.jl")
    include("phase5_tags.jl")
    include("phase6_buffers.jl")
    include("phase7_inspect.jl")
    include("phase8_field_types.jl")
    include("phase9_protocol_headers.jl")
    include("phase11_header_macro.jl")
    include("phase12_draft.jl")
    include("phase13_variable_length.jl")
    include("phase14_repeated.jl")
    include("phase15_options.jl")
    include("phase16_variants.jl")
    include("phase17_round_trip.jl")
end
