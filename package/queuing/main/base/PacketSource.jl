"""
    PacketSourceModule

**Making the packets a source hands out.**

The two source elements differ in who decides when a packet appears — the
source itself, or whoever pulls from it — but not in what appears, so the
description of the packet lives here: how long it is, and what it is tagged
with.

Length may be [`Volatile`](@ref), and then every packet gets its own draw from
the source's own generator, which is how a source produces a distribution of
sizes rather than one size. The content is length only: a
[`Filler`](@ref) costs one integer whatever it stands for, and nothing in the
queuing elements reads payload bytes. A source of real content builds its
packets itself.

INET also names each packet, from a format string with directives for the
module, the packet number and the time. Packets here carry tags rather than
names, and nothing dispatches on a name, so the format is not ported.
"""
module PacketSourceModule

using OmnetppSimulator: SimTime, MersenneTwister
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, Chunk, Filler, BitLength, Bits, Bytes, bits,
    set_tag!, get_tag, has_tag

export CreationTimeTag, PacketTemplate, create_packet, packet_creation_time

"""
    CreationTimeTag(time)

When a packet was created, attached by the source that made it. A sink works
out how long a packet lived by subtracting it from the time of arrival, which is
the one thing a packet cannot tell you about itself.
"""
struct CreationTimeTag
    time::SimTime
end

"""
    PacketTemplate(; length = Bytes(1000), attach_creation_time = true)

What the packets of a source look like.

`length` is a [`BitLength`](@ref), a plain number of bits, or a
[`Volatile`](@ref) drawn per packet.
"""
struct PacketTemplate
    length::Any
    attach_creation_time::Bool
end

PacketTemplate(; length = Bytes(1000), attach_creation_time::Bool = true) =
    PacketTemplate(length, attach_creation_time)

_packet_length(length::BitLength, ::MersenneTwister) = length
_packet_length(length, rng::MersenneTwister) = Bits(round(Int, evaluate(length, rng)))

"""
    create_packet(template, rng, time) -> Packet

One packet as `template` describes it, drawn against `rng` and stamped with
`time`.
"""
function create_packet(template::PacketTemplate, rng::MersenneTwister, time::SimTime)
    packet = Packet(Filler(_packet_length(template.length, rng)))
    template.attach_creation_time && set_tag!(packet, CreationTimeTag(time))
    packet
end

"""
    packet_creation_time(packet) -> SimTime or nothing

When the packet was created, or `nothing` when its source did not say.
"""
packet_creation_time(packet::Packet) =
    has_tag(packet, CreationTimeTag) ? get_tag(packet, CreationTimeTag).time : nothing

end # module
