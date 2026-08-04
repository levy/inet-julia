# ============================================================================
# packet_api_demo.jl
#
# A worked example showing the packet & chunk API in use, framed around the
# migration `RoutingModel.jl:18`'s tiny `Packet` type will eventually take.
#
#     using InetPacketExample
#     packet_api_demo()
#
# The declarations below are module-level on purpose: `@header` defines a
# struct, so it cannot live inside the demo function. `packet_api_demo` is only
# the narrated run at the bottom.
# ============================================================================

# --- 1. Declare the headers that will describe a routed packet -------------
# The routing model today stores src/dest/hop_count/byte_length/creation_time
# as fields on a mutable struct. Under the new API, control info that stays
# with the packet through the network is a packet TAG (Req/Ind convention);
# only bytes that would be on the wire live in `content`.

@header Ipv4Header begin
    version      :: UInt8  | 4
    ihl          :: UInt8  | 4
    dscp         :: UInt8  | 6
    ecn          :: UInt8  | 2
    total_length :: UInt16
    identification :: UInt16
    flags        :: UInt8  | 3
    frag_offset  :: UInt16 | 13
    ttl          :: UInt8
    protocol     :: UInt8
    checksum     :: UInt16
    src_addr     :: UInt32
    dst_addr     :: UInt32
end

# Simulator-internal tags (never on the wire, but travel with the packet).
struct RoutingRequest        # replaces `dest_addr` on the old Packet
    dest::UInt32
end
struct CreationTimeTag       # replaces `creation_time`
    t_ns::Int64
end
struct HopCountTag           # replaces `hop_count`
    n::Int
end

# --- 2. Build a packet the way an App would --------------------------------
"""
    make_packet(src, dest, payload_bytes, t_ns) -> Packet

An IPv4 packet over a `Filler` payload, tagged with the simulator-internal
control info that used to be fields on the routing model's `Packet` struct.
"""
function make_packet(src::UInt32, dest::UInt32, payload_bytes::Int, t_ns::Int64)
    # Payload never allocates bytes — the whole point of R1.
    payload = Filler(Bytes(payload_bytes); fill = 0x00)
    # IPv4 header, built field-wise. Immutable — sharing is safe.
    ip = Ipv4Header(4, 5, 0, 0, UInt16(payload_bytes + 20), UInt16(0),
                    UInt8(0), UInt16(0), UInt8(64), UInt8(17), UInt16(0),
                    src, dest)
    # Envelope + push header at the front.
    pk = Packet(payload)
    pushfirst!(pk, ip)
    # Tags for simulator-internal control info.
    set_tag!(pk, RoutingRequest(dest))
    set_tag!(pk, CreationTimeTag(t_ns))
    set_tag!(pk, HopCountTag(0))
    return pk
end

# --- 3. Per-hop routing: mutate the envelope, share the content ------------
"""
    forward!(pk) -> Packet

One hop: decrement the IPv4 TTL and bump the hop-count tag. The envelope
changes; the payload chunk is untouched and stays shared with any duplicate.
"""
function forward!(pk::Packet)
    # Read the header — type-directed, type-stable, no allocation.
    ip = peek(pk, Ipv4Header)
    # "Mutate" the header in place: update! rebuilds one Sequence node.
    # Under the hood this is a functional update — the OLD IP header still
    # exists, unchanged; a fresh one with ttl-1 is spliced in.
    new_ip = Ipv4Header(ip.version, ip.ihl, ip.dscp, ip.ecn, ip.total_length,
                        ip.identification, ip.flags, ip.frag_offset,
                        UInt8(ip.ttl - 1), ip.protocol, ip.checksum,
                        ip.src_addr, ip.dst_addr)
    popfirst!(pk, chunk_length(Ipv4Header))
    pushfirst!(pk, new_ip)
    # Bump the hop count tag.
    hc = get_tag(pk, HopCountTag)
    set_tag!(pk, HopCountTag(hc.n + 1))
    return pk
end

# --- 4. Broadcast: dup is O(1), payload is SHARED --------------------------
"""
    broadcast_packet(pk, n) -> Vector{Packet}

`n` duplicates of `pk`. `dup` is O(1): every copy points at the same payload
chunk, and only the envelopes are distinct.

(Named `broadcast_packet`, not `broadcast`: this is a package, and the bare
name would shadow and re-export `Base.broadcast`.)
"""
broadcast_packet(pk::Packet, n::Int) = [dup(pk) for _ in 1:n]

# --- 5. The demo -----------------------------------------------------------

"""
    packet_api_demo(; io = stdout, receivers = 3, payload_bytes = 1500)
        -> (; packet, copies)

A narrated tour of the packet & chunk API: build a tagged IPv4 packet,
broadcast it (payload shared), forward each copy one hop (envelopes diverge),
render one as bytes on the wire, and show what the R9 reinterpretation guard
does and does not refuse.

Returns the original packet and the forwarded copies so a REPL session can keep
poking at them; `io` is where the narration goes.
"""
function packet_api_demo(; io::IO = stdout, receivers::Int = 3,
                         payload_bytes::Int = 1500)
    println(io, "--- packet_api_demo ---\n")

    pk = make_packet(UInt32(0x0a000001), UInt32(0x0a000002), payload_bytes, Int64(1000))
    println(io, "Fresh packet:")
    println(io, describe(pk))

    # One receiver, N copies. All point at the SAME payload chunk.
    copies = broadcast_packet(pk, receivers)
    println(io, "Broadcast to $(length(copies)) receivers.")
    println(io, "  Original payload is shared: ",
            all(c.content === copies[1].content for c in copies))

    # Forward each: envelope mutates, content is unaffected in the OTHERS.
    foreach(forward!, copies)
    println(io, "After one hop each:")
    for (i, c) in enumerate(copies)
        ip = peek(c, Ipv4Header)
        hc = get_tag(c, HopCountTag)
        println(io, "  copy #$i: ttl=$(ip.ttl), hop_count=$(hc.n), payload=$(chunk_length(peek(c; at=chunk_length(Ipv4Header)))) bytes")
    end

    # Bytes-on-the-wire view: same packet as a serialised byte string.
    println(io, "\nWire view of copy #1 (first 32 bytes):")
    raw = peek(copies[1], Raw)
    n = min(32, length(raw.data))
    println(io, "  ", join([string(b, base=16, pad=2) for b in raw.data[1:n]], " "), "…")

    # R9 guard demo: what reinterpretation is and is not refused.
    println(io, "\nR9 guard: which reinterpretations are refused.")
    try
        peek(pk, Ipv4Header; at = Bytes(20))  # payload bytes, not an IPv4 header
        println(io, "  bytes → any Fields is ALLOWED; R9 fires on Fields → different Fields.")
    catch e
        println(io, "  refused: ", sprint(showerror, e))
    end

    return (; packet = pk, copies = copies)
end
