# ============================================================================
# Phase 16 — one wire format, many concrete types.
#
# The family below is ICMP's shape in miniature, under names of its own: the
# library declares the real one in `protocol/Icmp.jl`, and a fixture that took
# its names would shadow it.
#
# 158 of INET's 206 coded formats are served by a codec that reads a
# discriminator and then casts. `IcmpHeaderSerializer` reads three fields,
# switches on the type, and then copies those three fields into the concrete
# header by hand, once per case — and the C++ branch had to fix a case that
# forgot them (`28a8970d9d`, "copy the action-frame fields when deserializing a
# DELBA").
#
# Here the base is an embedded field, so nothing is copied and nothing can be
# forgotten. A variant is a family: an abstract type and three methods, the
# same shape an option family has.
# ============================================================================
using Test
using InetPacket.PacketModule

hex16(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

const PROBE_REPLY    = 0x00
const PROBE_REQUEST  = 0x08
const PROBE_UNKNOWN = 0x0b

abstract type ProbeMessage <: Fields end

@header ProbeBase <: ProbeMessage begin
    type     :: U8
    code     :: U8         = 0
    checksum :: Checksum16 = 0
end

@header ProbeRequest <: ProbeMessage begin
    base            :: ProbeBase
    identifier      :: U16
    sequence_number :: U16
end

@header ProbeReply <: ProbeMessage begin
    base            :: ProbeBase
    identifier      :: U16
    sequence_number :: U16
end

PacketModule.list_variants(::Type{ProbeMessage}) = (ProbeRequest, ProbeReply)
PacketModule.variant_base(::Type{ProbeMessage}) = ProbeBase
PacketModule.matches_variant(::Type{ProbeRequest}, base) = base.type == PROBE_REQUEST
PacketModule.matches_variant(::Type{ProbeReply}, base)   = base.type == PROBE_REPLY

echo_request() = ProbeRequest(base = ProbeBase(type = PROBE_REQUEST),
                                 identifier = 0x1234, sequence_number = 1)

# --- the family --------------------------------------------------------------

@testset "a variant family is an abstract type and three methods" begin
    @test ProbeRequest <: ProbeMessage
    @test ProbeBase <: ProbeMessage
    @test list_variants(ProbeMessage) == (ProbeRequest, ProbeReply)
    @test variant_base(ProbeMessage) === ProbeBase

    @test select_variant(ProbeMessage, ProbeBase(type = PROBE_REQUEST)) ===
          ProbeRequest
    @test select_variant(ProbeMessage, ProbeBase(type = PROBE_REPLY)) ===
          ProbeReply
    # Nothing claims it, so the base is the answer.
    @test select_variant(ProbeMessage, ProbeBase(type = PROBE_UNKNOWN)) ===
          ProbeBase

    # A header that is not a family costs nothing for any of this.
    @test list_variants(UdpHeader) == ()
end

@testset "a family has no length of its own, only a least one" begin
    @test !is_fixed_length(ProbeMessage)
    @test minimum_chunk_length(ProbeMessage) == Bytes(4)     # the base
    @test chunk_length(ProbeRequest) == Bytes(8)
    @test chunk_length(ProbeBase) == Bytes(4)
    # The family describes its base, which is all a reader knows in advance.
    @test [f.name for f in describe_layout(ProbeMessage).fields] ==
          [:type, :code, :checksum]
end

# --- the read path -----------------------------------------------------------

@testset "the reader builds the member the discriminator names" begin
    bytes = encode_header(echo_request())
    @test hex16(bytes) == "08 00 00 00 12 34 00 01"

    decoded = decode_header(ProbeMessage, bytes)
    @test decoded isa ProbeRequest
    @test decoded.identifier == 0x1234
    @test decoded.sequence_number == 1
    # The base's fields are there, and nothing copied them.
    @test decoded.base.type == PROBE_REQUEST
    @test decoded.base.code == 0
    @test encode_header(decoded) == bytes

    reply = ProbeReply(base = ProbeBase(type = PROBE_REPLY),
                          identifier = 0x1234, sequence_number = 1)
    @test decode_header(ProbeMessage, encode_header(reply)) isa ProbeReply
end

@testset "a type nobody models comes back as the base, marked" begin
    # This is INET's `markImproperlyRepresented`: the bytes are intact and the
    # model does not describe them, so an unknown subtype still re-serializes
    # byte for byte.
    wire = UInt8[PROBE_UNKNOWN, 0x00, 0x00, 0x00]
    marked = decode_header(ProbeMessage, wire)
    @test marked isa MarkedFields{ProbeBase}
    @test quality(marked) == Q_MISREPRESENTED
    @test marked.header.type == PROBE_UNKNOWN
    @test encode_header(marked.header) == wire
end

# --- the peek gate -----------------------------------------------------------

@testset "peek returns the member, and gates on the mark" begin
    @test peek(Raw(encode_header(echo_request())), ProbeMessage) isa ProbeRequest

    wire = UInt8[PROBE_UNKNOWN, 0x00, 0x00, 0x00]
    @test_throws ErrorException peek(Raw(wire), ProbeMessage)
    accepted = peek(Raw(wire), ProbeMessage; misrepresented = true)
    @test accepted isa ProbeBase
    @test accepted.type == PROBE_UNKNOWN
end

# --- what embedding buys -----------------------------------------------------

@testset "the base is embedded, so no case can forget to copy it" begin
    # Every field of `ProbeRequest` is declared once, the base's included,
    # and the codec reads them from that one declaration. There is no per-case
    # copy to omit — which is the defect the C++ branch fixed for DELBA.
    @test fieldnames(ProbeRequest) == (:base, :identifier, :sequence_number)
    @test fieldtype(ProbeRequest, :base) === ProbeBase
    @test measure_field(ProbeBase) == 32

    # Change the base and the member follows, with no second declaration.
    changed = set_field(echo_request(), :base, ProbeBase(type = PROBE_REQUEST,
                                                          code = 3))
    @test encode_header(changed)[2] == 3
    @test decode_header(ProbeMessage, encode_header(changed)).base.code == 3
end
