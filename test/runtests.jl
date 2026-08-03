using Test

# Packet & chunk API (plan/done/packet-chunk-api.md) — phased conformance
# suite; each phase adds a file.
@testset "packet & chunk API" begin
    include("packet/phase1_chunks.jl")
    include("packet/phase2_packet.jl")
    include("packet/phase3_headers.jl")
    include("packet/phase4_quality.jl")
    include("packet/phase5_tags.jl")
    include("packet/phase6_buffers.jl")
    include("packet/phase7_inspect.jl")
end
