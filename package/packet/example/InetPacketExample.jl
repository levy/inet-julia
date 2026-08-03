"""
    InetPacketExample

Runnable demonstrations of `InetPacket`: `packet_api_demo.jl`, a worked tour of
the packet & chunk API — headers, tags, quality, and what `peek` materialises.

Each is a standalone script rather than a registered example object — they
print, they do not open an editor. Run one with:

    julia --project=package/packet/example package/packet/example/packet_api_demo.jl

`script_path(name)` locates them so a test or a driver can find them by name.
"""
module InetPacketExample

"""
    script_path(name::AbstractString) -> String

Absolute path to a bundled example script, with or without the `.jl` suffix
(`script_path("packet_api_demo")`).
"""
function script_path(name::AbstractString)
    file = endswith(name, ".jl") ? String(name) : String(name) * ".jl"
    path = abspath(joinpath(@__DIR__, file))
    isfile(path) || error("no example script named ", repr(name), " at ", path)
    path
end

"""
    scripts() -> Vector{String}

Every bundled example script name, without the `.jl` suffix.
"""
scripts() = sort([replace(f, ".jl" => "") for f in readdir(@__DIR__)
                  if endswith(f, ".jl") && f != "InetPacketExample.jl"])

export script_path, scripts

end # module InetPacketExample
