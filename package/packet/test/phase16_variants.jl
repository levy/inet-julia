# ============================================================================
# Phase 16 — one wire format, many concrete types.
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

const ICMP_ECHO_REPLY    = 0x00
const ICMP_ECHO_REQUEST  = 0x08
const ICMP_TIME_EXCEEDED = 0x0b

abstract type IcmpMessage <: Fields end

@header IcmpHeader <: IcmpMessage begin
    type     :: U8
    code     :: U8         = 0
    checksum :: Checksum16 = 0
end

@header IcmpEchoRequest <: IcmpMessage begin
    base            :: IcmpHeader
    identifier      :: U16
    sequence_number :: U16
end

@header IcmpEchoReply <: IcmpMessage begin
    base            :: IcmpHeader
    identifier      :: U16
    sequence_number :: U16
end

PacketModule.list_variants(::Type{IcmpMessage}) = (IcmpEchoRequest, IcmpEchoReply)
PacketModule.variant_base(::Type{IcmpMessage}) = IcmpHeader
PacketModule.matches_variant(::Type{IcmpEchoRequest}, base) = base.type == ICMP_ECHO_REQUEST
PacketModule.matches_variant(::Type{IcmpEchoReply}, base)   = base.type == ICMP_ECHO_REPLY

echo_request() = IcmpEchoRequest(base = IcmpHeader(type = ICMP_ECHO_REQUEST),
                                 identifier = 0x1234, sequence_number = 1)

# --- the family --------------------------------------------------------------

@testset "a variant family is an abstract type and three methods" begin
    @test IcmpEchoRequest <: IcmpMessage
    @test IcmpHeader <: IcmpMessage
    @test list_variants(IcmpMessage) == (IcmpEchoRequest, IcmpEchoReply)
    @test variant_base(IcmpMessage) === IcmpHeader

    @test select_variant(IcmpMessage, IcmpHeader(type = ICMP_ECHO_REQUEST)) ===
          IcmpEchoRequest
    @test select_variant(IcmpMessage, IcmpHeader(type = ICMP_ECHO_REPLY)) ===
          IcmpEchoReply
    # Nothing claims it, so the base is the answer.
    @test select_variant(IcmpMessage, IcmpHeader(type = ICMP_TIME_EXCEEDED)) ===
          IcmpHeader

    # A header that is not a family costs nothing for any of this.
    @test list_variants(UdpHeader) == ()
end

@testset "a family has no length of its own, only a least one" begin
    @test !is_fixed_length(IcmpMessage)
    @test minimum_chunk_length(IcmpMessage) == Bytes(4)     # the base
    @test chunk_length(IcmpEchoRequest) == Bytes(8)
    @test chunk_length(IcmpHeader) == Bytes(4)
    # The family describes its base, which is all a reader knows in advance.
    @test [f.name for f in describe_layout(IcmpMessage).fields] ==
          [:type, :code, :checksum]
end

# --- the read path -----------------------------------------------------------

@testset "the reader builds the member the discriminator names" begin
    bytes = encode_header(echo_request())
    @test hex16(bytes) == "08 00 00 00 12 34 00 01"

    decoded = decode_header(IcmpMessage, bytes)
    @test decoded isa IcmpEchoRequest
    @test decoded.identifier == 0x1234
    @test decoded.sequence_number == 1
    # The base's fields are there, and nothing copied them.
    @test decoded.base.type == ICMP_ECHO_REQUEST
    @test decoded.base.code == 0
    @test encode_header(decoded) == bytes

    reply = IcmpEchoReply(base = IcmpHeader(type = ICMP_ECHO_REPLY),
                          identifier = 0x1234, sequence_number = 1)
    @test decode_header(IcmpMessage, encode_header(reply)) isa IcmpEchoReply
end

@testset "a type nobody models comes back as the base, marked" begin
    # This is INET's `markImproperlyRepresented`: the bytes are intact and the
    # model does not describe them, so an unknown subtype still re-serializes
    # byte for byte.
    wire = UInt8[ICMP_TIME_EXCEEDED, 0x00, 0x00, 0x00]
    marked = decode_header(IcmpMessage, wire)
    @test marked isa MarkedFields{IcmpHeader}
    @test quality(marked) == Q_MISREPRESENTED
    @test marked.header.type == ICMP_TIME_EXCEEDED
    @test encode_header(marked.header) == wire
end

# --- the peek gate -----------------------------------------------------------

@testset "peek returns the member, and gates on the mark" begin
    @test peek(Raw(encode_header(echo_request())), IcmpMessage) isa IcmpEchoRequest

    wire = UInt8[ICMP_TIME_EXCEEDED, 0x00, 0x00, 0x00]
    @test_throws ErrorException peek(Raw(wire), IcmpMessage)
    accepted = peek(Raw(wire), IcmpMessage; misrepresented = true)
    @test accepted isa IcmpHeader
    @test accepted.type == ICMP_TIME_EXCEEDED
end

# --- what embedding buys -----------------------------------------------------

@testset "the base is embedded, so no case can forget to copy it" begin
    # Every field of `IcmpEchoRequest` is declared once, the base's included,
    # and the codec reads them from that one declaration. There is no per-case
    # copy to omit — which is the defect the C++ branch fixed for DELBA.
    @test fieldnames(IcmpEchoRequest) == (:base, :identifier, :sequence_number)
    @test fieldtype(IcmpEchoRequest, :base) === IcmpHeader
    @test measure_field(IcmpHeader) == 32

    # Change the base and the member follows, with no second declaration.
    changed = set_field(echo_request(), :base, IcmpHeader(type = ICMP_ECHO_REQUEST,
                                                          code = 3))
    @test encode_header(changed)[2] == 3
    @test decode_header(IcmpMessage, encode_header(changed)).base.code == 3
end
