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

# --- 1. The headers that will describe a routed packet ---------------------
# `Ipv4Header` and `UdpHeader` are declared by `InetPacket` itself, in
# `packet/main/protocol/`. A catalog page embeds those files whole: a marker
# names a top-level definition, and a macro call whose first argument is a bare
# identifier — which is what `@header Ipv4Header begin … end` is — has no name
# the marker can ask for.
#
# The routing model today stores src/dest/hop_count/byte_length/creation_time
# as fields on a mutable struct. Under the new API, control info that stays
# with the packet through the network is a packet TAG (Req/Ind convention);
# only bytes that would be on the wire live in `content`.

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
    # IPv4 header. Immutable — sharing is safe. The keyword form states what
    # this datagram decides; version, ihl and the TTL take their defaults.
    ip = Ipv4Header(total_length = UInt16(payload_bytes + 20),
                    protocol = IP_PROTOCOL_UDP,
                    source = src, destination = dest)
    # Envelope + push header at the front.
    pk = Packet(payload)
    pushfirst!(pk, ip)
    # Tags for simulator-internal control info.
    set_tag!(pk, RoutingRequest(dest))
    set_tag!(pk, CreationTimeTag(t_ns))
    set_tag!(pk, HopCountTag(0))
    return pk
end

"""
    make_frame(; payload_bytes = 32) -> Packet

The same datagram, on the wire: an Ethernet MAC header over an IPv4 header over
a UDP header over a `Filler` payload, with the frame check sequence behind it.

Four declared headers and one opaque run — which is what makes it the packet
worth drawing. A stack of one header shows nothing about how headers follow one
another through the bytes.
"""
function make_frame(; payload_bytes::Int = 32)
    pk = Packet(Filler(Bytes(payload_bytes); fill = 0x00))
    pushfirst!(pk, UdpHeader(source_port = 1000, destination_port = 2000,
                             length = UInt16(payload_bytes + 8)))
    pushfirst!(pk, Ipv4Header(total_length = UInt16(payload_bytes + 28),
                              protocol = IP_PROTOCOL_UDP,
                              source = Ipv4Address("10.0.0.1"),
                              destination = Ipv4Address("10.0.0.2")))
    pushfirst!(pk, EthernetMacHeader(MacAddress("0a:00:00:00:00:02"),
                                     MacAddress("0a:00:00:00:00:01"),
                                     ETHERTYPE_IPV4))
    push!(pk, EthernetFcs())
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
    # "Mutate" the header: `set_field` is a functional update, so the OLD IP
    # header still exists, unchanged, and a fresh one with one less hop to live
    # is spliced in.
    new_ip = set_field(ip, :time_to_live, ip.time_to_live - 1)
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

# --- 5. What the reinterpretation guard refuses ----------------------------

"""
    reinterpretation_guard() -> (; refused, forced)

What `peek` refuses and what it allows across header types. Reading an
`Ipv4Header` as a `UdpHeader` is almost always a bug — the two are laid out
differently — so it is refused, and `refused` is the message. Passing
`reinterpret = true` forces it through, and `forced` is the nonsense that comes
out: the same twenty bytes read under the wrong layout.

Bytes are not gated the same way. Deserialising a header out of raw bytes is
the ordinary case and needs no opt-in, because bytes carry no claim about what
they are.
"""
function reinterpretation_guard()
    ip = peek(make_packet(UInt32(0x0a000001), UInt32(0x0a000002), 40, Int64(0)),
              Ipv4Header)
    refused = try
        peek(ip, UdpHeader)
        nothing
    catch err
        sprint(showerror, err)
    end
    return (; refused = refused, forced = peek(ip, UdpHeader; reinterpret = true))
end

# --- 6. Knowing what you know: the quality lattice --------------------------

"""
    truncated_packet(; payload_bytes = 40) -> Packet

A packet whose header a receiver could not fully reconstruct — the shape a
truncated frame leaves behind. The header is marked incomplete, the mark
travels with it into the packet, and `quality` reports it from the outside.

Marking wraps rather than mutates: the `Ipv4Header` struct inside is the same
immutable value it always was, which is what keeps headers cheap and sharable.
"""
function truncated_packet(; payload_bytes::Int = 40)
    ip = peek(make_packet(UInt32(0x0a000001), UInt32(0x0a000002), payload_bytes,
                          Int64(0)), Ipv4Header)
    pk = Packet(Filler(Bytes(payload_bytes); fill = 0x00))
    pushfirst!(pk, mark_incomplete(ip))
    return pk
end

"""
    strict_peek(pk) -> (; refused, accepted)

The gate, both ways round. `peek(pk, Ipv4Header)` on a packet whose header is
marked refuses and says which flag stopped it; the same call with
`incomplete = true` reads the header anyway. Nothing is silently returned:
imperfect data has to be asked for by name.
"""
function strict_peek(pk::Packet)
    refused = try
        peek(pk, Ipv4Header)
        nothing
    catch err
        sprint(showerror, err)
    end
    return (; refused = refused, accepted = peek(pk, Ipv4Header; incomplete = true))
end

# --- 7. Reassembly without ceremony ----------------------------------------

"""
    reassemble_out_of_order(; segment_bytes = 10) -> (; gaps_after, assembled)

Three segments of a thirty-byte message, delivered last-middle-first, written
into a `ChunkBuffer` at their offsets. `gaps_after` is the gap list after each
insertion — the buffer's own answer to "what am I still missing", in bits — and
`assembled` is the whole message once there are none.

Nobody sorts anything here. The buffer keeps its regions ordered and coalesces
neighbours as they meet, so arrival order is not the receiver's problem.
"""
function reassemble_out_of_order(; segment_bytes::Int = 10)
    buffer = ChunkBuffer()
    whole = 0:(Bytes(3 * segment_bytes).bits - 1)
    segment(fill_byte) = Raw(UInt8[fill_byte for _ in 1:segment_bytes])
    gaps_after = Vector{UnitRange{Int64}}[]
    for (index, fill_byte) in ((2, 0xcc), (0, 0xaa), (1, 0xbb))
        write!(buffer, Bytes(index * segment_bytes), segment(fill_byte))
        push!(gaps_after, gaps(buffer, whole))
    end
    return (; gaps_after = gaps_after, assembled = assembled_chunk(buffer, whole))
end

"""
    straddling_pop(; chunk_bytes = 4, take_bytes = 6) -> (; taken, left)

A `ChunkQueue` pop that crosses a chunk boundary. Two chunks go in; six bytes
come out of an eight-byte queue, spanning both. The caller asked for a length,
not for a chunk, and got exactly that length — the boundary between the two
chunks is the queue's business, not the reader's.
"""
function straddling_pop(; chunk_bytes::Int = 4, take_bytes::Int = 6)
    queue = ChunkQueue()
    push!(queue, Raw(UInt8[0x01 for _ in 1:chunk_bytes]))
    push!(queue, Raw(UInt8[0x02 for _ in 1:chunk_bytes]))
    taken = popfirst!(queue, Bytes(take_bytes))
    return (; taken = peek(taken, Raw).data, left = total_length(queue))
end

# --- 8. The demo -----------------------------------------------------------

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
        println(io, "  copy #$i: ttl=$(ip.time_to_live), hop_count=$(hc.n), payload=$(chunk_length(peek(c; at=chunk_length(Ipv4Header)))) bytes")
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
