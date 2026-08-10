# ============================================================================
# Phase 10 — the field-value half of the header language.
#
# Five capabilities, each with a real INET format behind it:
#
#   byte order      IEEE 802.11 writes its Duration field least significant
#                   byte first
#   signed          `Ieee80211MacHeader` uses -1 for "no association identifier"
#   wide            an IPv6 address is 128 bits, which no `UInt64` holds
#   model only      INET's `ChecksumMode` is state the protocol needs and the
#                   wire never sees
#   wire only       `Ieee80211MpduSubframeHeader` writes a constant 0x4E that
#                   no field holds
#
# The headers below are test fixtures, not the library's wire formats. They
# exist to press one capability each; the real formats live in `protocol/`.
# ============================================================================
using Test
using InetPacket.PacketModule

hex10(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- byte order --------------------------------------------------------------

@header ByteOrderProbe begin
    big    :: UInt16 | 16
    little :: UInt16 | 16 | le
end

@testset "byte order — a field writes least significant byte first" begin
    probe = ByteOrderProbe(0x1234, 0x1234)
    @test hex10(to_bytes(probe)) == "12 34 34 12"
    @test from_bytes(ByteOrderProbe, to_bytes(probe)) == probe
    @test chunk_length(ByteOrderProbe) == Bytes(4)

    # The order is a property of the field, not of the writer, so the two
    # fields of one header may disagree — which is what 802.11 needs.
    @test to_bytes(ByteOrderProbe(0x00ff, 0x00ff)) == UInt8[0x00, 0xff, 0xff, 0x00]
end

@testset "byte order — a sub-byte field has no byte order" begin
    # The byte is the unit the order applies to, so the question has no answer
    # for a 12-bit field. The macro expands, and the codec refuses.
    @test_throws ErrorException write_bits!(BitWriter(), UInt16(1), 12, :le)
    @test_throws ErrorException read_bits!(BitReader(UInt8[0, 0]), 12, :le)
    @test_throws ErrorException write_bits!(BitWriter(), UInt16(1), 16, :middle)
end

# --- signed integers ---------------------------------------------------------

@header SignedProbe begin
    narrow :: Int16 | 12
    wide   :: Int32 | 32
    small  :: Int8  | 8
end

@testset "signed — two's complement over the DECLARED width" begin
    # -1 in twelve bits is 0xfff, not 0xffff: the width the declaration gives
    # is the width the sign lives in. The three fields are 52 bits together,
    # so `wide` and `small` both straddle a byte boundary.
    @test chunk_length(SignedProbe) == Bits(52)
    probe = SignedProbe(Int16(-1), Int32(-2), Int8(-128))
    @test hex10(to_bytes(probe)) == "ff ff ff ff ff e8 00"
    @test from_bytes(SignedProbe, to_bytes(probe)) == probe

    @test from_bytes(SignedProbe, to_bytes(SignedProbe(Int16(2047), Int32(7), Int8(127)))) ==
          SignedProbe(Int16(2047), Int32(7), Int8(127))
    # The most negative and the most positive value a 12-bit field holds.
    @test from_bytes(SignedProbe, to_bytes(SignedProbe(Int16(-2048), Int32(0), Int8(0)))).narrow ==
          Int16(-2048)
end

@testset "signed — sign_extend is the rule the reader uses" begin
    @test sign_extend(UInt64(0xfff), 12) == -1
    @test sign_extend(UInt64(0x7ff), 12) == 2047
    @test sign_extend(UInt64(0x800), 12) == -2048
    @test sign_extend(UInt64(0), 12) == 0
    @test sign_extend(typemax(UInt64), 64) == -1
end

# --- a field wider than 64 bits ----------------------------------------------

@testset "Ipv6Address — text in, text out" begin
    @test string(Ipv6Address("2001:db8::1")) == "2001:db8::1"
    @test string(Ipv6Address("::")) == "::"
    @test string(Ipv6Address("::1")) == "::1"
    # RFC 5952: shorten the longest run of zero groups, and only a run of two.
    @test string(Ipv6Address("fe80:0:0:0:1:2:3:4")) == "fe80::1:2:3:4"
    @test string(Ipv6Address("1:0:2:0:0:3:0:4")) == "1:0:2::3:0:4"
    @test Ipv6Address("2001:db8:0:0:0:0:0:1") == Ipv6Address("2001:db8::1")
    @test ipv6_groups(Ipv6Address("2001:db8::1"))[1] == 0x2001
    @test_throws ErrorException Ipv6Address("1:2:3")
end

@testset "Ipv6Header — 40 bytes, and the wire order the serializer writes" begin
    @test chunk_length(Ipv6Header) == Bytes(IPV6_HEADER_BYTES)
    @test chunk_length(Ipv6Header) == Bytes(40)

    header = Ipv6Header(payload_length = 0x0028,
                        next_header = IP_PROTOCOL_UDP,
                        src_address = Ipv6Address("2001:db8::1"),
                        dst_address = Ipv6Address("2001:db8::2"))
    bytes = to_bytes(header)
    @test Base.length(bytes) == 40
    # version(4) traffic_class(8) flow_label(20) | payload_length(16)
    # next_header(8) hop_limit(8) | src(128) | dst(128)
    @test hex10(bytes[1:8]) == "60 00 00 00 00 28 11 40"
    @test hex10(bytes[9:24]) == "20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 01"
    @test hex10(bytes[25:40]) == "20 01 0d b8 00 00 00 00 00 00 00 00 00 00 00 02"
    @test from_bytes(Ipv6Header, bytes) == header
end

@testset "Ipv6Header — the traffic class splits into DSCP and ECN" begin
    header = Ipv6Header(traffic_class = ipv6_traffic_class(46, 2),
                        payload_length = 0, next_header = IP_PROTOCOL_UDP,
                        src_address = IPV6_UNSPECIFIED, dst_address = IPV6_LOOPBACK)
    @test ipv6_traffic_class(46, 2) == 0xba
    @test ipv6_dscp(header) == 46
    @test ipv6_ecn(header) == 2
    # The traffic class straddles a byte boundary: the version takes the first
    # four bits, so 0xba goes out as 0x_b then 0xa_.
    @test to_bytes(header)[1] == 0x6b
    @test to_bytes(header)[2] == 0xa0
end

@testset "a wide field has no UInt64, and says so" begin
    layout = header_layout(Ipv6Header)
    source = layout.fields[findfirst(f -> f.name === :src_address, layout.fields)]
    @test source.width == 128
    @test source.base === :ipv6
    header = Ipv6Header(payload_length = 0, next_header = IP_PROTOCOL_UDP,
                        src_address = Ipv6Address("2001:db8::1"),
                        dst_address = IPV6_LOOPBACK)
    @test_throws ErrorException field_bits(header, source)
    @test field_text(header, source) == "2001:db8::1"
end

# --- a model-only field ------------------------------------------------------

@enum ProbeChecksumMode PROBE_DECLARED = 0 PROBE_COMPUTED = 1

@header ModelOnlyProbe begin
    checksum      :: UInt16 | 16 | hex        = 0x0000
    checksum_mode :: ProbeChecksumMode | 0    = PROBE_DECLARED
end

@testset "a model-only field is in the struct and not on the wire" begin
    probe = ModelOnlyProbe(0xbeef, PROBE_COMPUTED)
    @test chunk_length(ModelOnlyProbe) == Bytes(2)
    @test hex10(to_bytes(probe)) == "be ef"

    # The mode does not travel, so a reader gets the declared default back.
    @test from_bytes(ModelOnlyProbe, to_bytes(probe)).checksum_mode == PROBE_DECLARED
    @test from_bytes(ModelOnlyProbe, to_bytes(probe)).checksum == 0xbeef
    @test :checksum_mode in fieldnames(ModelOnlyProbe)

    # The layout describes the wire, so the mode is not a field of it.
    @test [f.name for f in header_layout(ModelOnlyProbe).fields] == [:checksum]
    @test header_layout(ModelOnlyProbe).length == Bytes(2)
end

# --- a wire-only field -------------------------------------------------------

@header WireOnlyProbe begin
    reserved  :: UInt8  | 4  | constant(0x00)
    length    :: UInt16 | 12
    crc       :: UInt8  | 8  | constant(0x00)
    signature :: UInt8  | 8  | constant(0x4E)
end

@testset "a wire-only field takes width and is not in the struct" begin
    # This is `Ieee80211MpduSubframeHeader`: a delimiter whose four bytes hold
    # one field the model has and three constants it does not.
    probe = WireOnlyProbe(0x0123)
    @test chunk_length(WireOnlyProbe) == Bytes(4)
    @test hex10(to_bytes(probe)) == "01 23 00 4e"
    @test fieldnames(WireOnlyProbe) == (:length,)
    @test from_bytes(WireOnlyProbe, to_bytes(probe)) == probe

    # A constant is discarded on read: a sender that wrote the wrong signature
    # still gives a header, and the value it wrote is gone.
    @test from_bytes(WireOnlyProbe, UInt8[0xf1, 0x23, 0xff, 0xff]) == WireOnlyProbe(0x0123)

    # The layout describes the wire, so every constant IS a field of it — the
    # diagram must draw the bits that are there.
    @test [f.name for f in header_layout(WireOnlyProbe).fields] ==
          [:reserved, :length, :crc, :signature]
    @test [f.offset for f in header_layout(WireOnlyProbe).fields] == [0, 4, 16, 24]
end

@testset "the layout carries a constant, so a view can read one" begin
    # Without this the diagram asks the struct for a field that is not there.
    layout = header_layout(WireOnlyProbe)
    signature = layout.fields[4]
    @test is_constant(signature)
    @test !is_constant(layout.fields[2])
    probe = WireOnlyProbe(0x0123)
    @test field_value(probe, signature) == 0x4E
    @test field_bits(probe, signature) == 0x4E
    @test field_text(probe, signature) == "78"
    @test field_value(probe, layout.fields[2]) == 0x0123
end

@testset "has_bits says which fields a UInt64 describes" begin
    @test all(has_bits, header_layout(WireOnlyProbe).fields)
    ipv6 = header_layout(Ipv6Header)
    @test count(has_bits, ipv6.fields) == 6
    @test count(!has_bits, ipv6.fields) == 2
end

# --- what the macro refuses --------------------------------------------------

@testset "the macro refuses a declaration it cannot mean" begin
    # A model-only field has no bits for a reader to fill, so it needs a default.
    @test_throws LoadError @eval @header BadModelOnly begin
        mode :: UInt8 | 0
    end
    # A constant is not in the struct, so a default has nothing to default.
    @test_throws LoadError @eval @header BadConstantDefault begin
        pad :: UInt8 | 8 | constant(0x00) = 0x01
    end
    # A display base the formatter does not know is a typo, not a base.
    @test_throws LoadError @eval @header BadBase begin
        value :: UInt8 | 8 | octal
    end
    # A clause of a later phase is named, so the error says which.
    @test_throws LoadError @eval @header BadClause begin
        value :: UInt8 | 8 | until(offset == Bytes(4))
    end
    # Every field a constant leaves no struct behind.
    @test_throws LoadError @eval @header BadAllConstant begin
        pad :: UInt8 | 8 | constant(0x00)
    end
end

# ============================================================================
# Phase 2 of the plan — a value the codec computes, and validation that marks.
#
#   derive    INET computes the TCP data offset in the serializer and throws
#             when the model disagrees
#   check     `Ipv6HeaderSerializer` calls `markIncorrect()` on a version that
#             is not 6, and hands the header back anyway
#   quality   a marked header travels in a `MarkedFields` envelope, and `peek`
#             refuses it until the caller opts in
# ============================================================================

# --- derive ------------------------------------------------------------------

@header DeriveProbe begin
    word_count :: UInt8  | 8 | derive(cld(bits(chunk_length(h)), 32))
    payload    :: UInt16 | 16
    trailer    :: UInt8  | 8
end

@testset "derive — the writer computes, the reader keeps what arrived" begin
    # 8 + 16 + 8 = 32 bits = one 32-bit word, whatever the struct says.
    @test hex10(to_bytes(DeriveProbe(0x00, 0xbeef, 0x11))) == "01 be ef 11"
    @test hex10(to_bytes(DeriveProbe(0x7f, 0xbeef, 0x11))) == "01 be ef 11"

    # The reader keeps the wire value, so a foreign sender's disagreement is
    # visible instead of silently corrected.
    @test from_bytes(DeriveProbe, UInt8[0x09, 0xbe, 0xef, 0x11]).word_count == 0x09
end

@header DeriveFromFieldsProbe begin
    total :: UInt16 | 16 | derive(UInt16(low) + UInt16(high))
    low   :: UInt8  | 8
    high  :: UInt8  | 8
end

@testset "derive — a clause reads the other fields by name" begin
    @test hex10(to_bytes(DeriveFromFieldsProbe(0x0000, 0x02, 0x03))) == "00 05 02 03"
    # A field declared BELOW the derived one is still readable: every field is
    # bound before any clause runs.
    @test from_bytes(DeriveFromFieldsProbe, to_bytes(DeriveFromFieldsProbe(0, 0x02, 0x03))).total ==
          0x0005
end

# --- check -------------------------------------------------------------------

@testset "check — a bad version marks incorrect and does NOT throw" begin
    header = Ipv6Header(payload_length = 0x0028, next_header = IP_PROTOCOL_UDP,
                        src_address = Ipv6Address("2001:db8::1"),
                        dst_address = IPV6_LOOPBACK)
    good = to_bytes(header)
    @test from_bytes(Ipv6Header, good) == header
    @test quality(from_bytes(Ipv6Header, good)) == Q_COMPLETE

    bad = copy(good)
    bad[1] = 0x50                       # version 5, which no IPv6 header has
    marked = from_bytes(Ipv6Header, bad)
    @test marked isa MarkedFields{Ipv6Header}
    @test quality(marked) == Q_INCORRECT
    @test is_incorrect(quality(marked))
    # The header is still there: a malformed packet is data, not an exception.
    @test marked.header.version == 5
    @test marked.header.src_address == Ipv6Address("2001:db8::1")
end

@testset "check — a header the MODEL built wrong throws on write" begin
    # The same check, the other way round. A version of 5 in a struct is a bug
    # in the code that built it, so serialising says so instead of emitting it.
    wrong = Ipv6Header(version = UInt8(5), payload_length = 0, next_header = IP_PROTOCOL_UDP,
                       src_address = IPV6_UNSPECIFIED, dst_address = IPV6_LOOPBACK)
    @test_throws ErrorException to_bytes(wrong)
end

@header HeaderCheckProbe begin
    low  :: UInt8 | 8
    high :: UInt8 | 8
    @check high >= low
end

@testset "check — a header-level @check spans fields" begin
    @test to_bytes(HeaderCheckProbe(0x01, 0x02)) == UInt8[0x01, 0x02]
    @test_throws ErrorException to_bytes(HeaderCheckProbe(0x02, 0x01))
    @test from_bytes(HeaderCheckProbe, UInt8[0x01, 0x02]) == HeaderCheckProbe(0x01, 0x02)
    @test quality(from_bytes(HeaderCheckProbe, UInt8[0x02, 0x01])) == Q_INCORRECT
end

@header ConstantCheckProbe begin
    signature :: UInt8 | 8 | constant(0x4E) | check(signature == 0x4E)
    payload   :: UInt8 | 8
end

@testset "check — a check on a constant tests what the SENDER wrote" begin
    probe = ConstantCheckProbe(0x11)
    @test hex10(to_bytes(probe)) == "4e 11"
    @test from_bytes(ConstantCheckProbe, UInt8[0x4e, 0x11]) == probe
    # The struct has no signature field, so the header is the same either way —
    # what differs is the mark.
    wrong = from_bytes(ConstantCheckProbe, UInt8[0xff, 0x11])
    @test wrong isa MarkedFields
    @test wrong.header == probe
end

# --- the peek gate -----------------------------------------------------------

@testset "peek gates on what the DESERIALISER said, not only on the source" begin
    header = Ipv6Header(payload_length = 0, next_header = IP_PROTOCOL_UDP,
                        src_address = Ipv6Address("2001:db8::1"),
                        dst_address = IPV6_LOOPBACK)
    bad = copy(to_bytes(header))
    bad[1] = 0x50
    source = Raw(bad)
    @test quality(source) == Q_COMPLETE          # the bytes themselves are fine

    @test_throws ErrorException peek(source, Ipv6Header)
    accepted = peek(source, Ipv6Header; incorrect = true)
    @test accepted isa Ipv6Header                 # the envelope is stripped
    @test accepted.version == 5

    # A header that passes its checks is untouched by any of this.
    @test peek(Raw(to_bytes(header)), Ipv6Header) == header
end

@testset "a header with no check is complete, and costs nothing" begin
    @test quality(from_bytes(UdpHeader, to_bytes(UdpHeader(src_port = 1, dst_port = 2,
                                                           length = 8)))) == Q_COMPLETE
    @test from_bytes(UdpHeader, UInt8[0, 1, 0, 2, 0, 8, 0, 0]) isa UdpHeader
end

# --- what the macro refuses, again -------------------------------------------

@testset "the macro refuses a derive it cannot honour" begin
    # A constant already states its value.
    @test_throws LoadError @eval @header BadConstantDerive begin
        pad :: UInt8 | 8 | constant(0x00) | derive(1)
    end
    # A model-only field is not on the wire, so there is nothing to write.
    @test_throws LoadError @eval @header BadModelDerive begin
        mode :: UInt8 | 0 | derive(1) = 0x00
    end
end

# --- a checksum, which is a derive plus a mode -------------------------------

@header ChecksumProbe begin
    src           :: UInt16 | 16
    dst           :: UInt16 | 16
    checksum      :: UInt16 | 16 | hex |
                     derive(checksum_mode == CHECKSUM_COMPUTED ?
                            internet_checksum(h) : checksum) = 0x0000
    checksum_mode :: ChecksumMode | 0 = CHECKSUM_DECLARED
end

@testset "ones_complement_checksum — RFC 1071" begin
    # The classic worked example of RFC 1071 §3.
    @test ones_complement_checksum(UInt8[0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]) ==
          0x220d
    # An odd length pads with a zero on the right, so a trailing zero is free.
    @test ones_complement_checksum(UInt8[0x12]) == ones_complement_checksum(UInt8[0x12, 0x00])
    @test ones_complement_checksum(UInt8[]) == 0xffff
end

@testset "checksum — declared writes what it holds, computed computes" begin
    # DECLARED is the default and the mode a capture round-trips under: the
    # stored value goes out untouched, however wrong it is.
    declared = ChecksumProbe(src = 0x0001, dst = 0x0002, checksum = 0xdead)
    @test hex10(to_bytes(declared)) == "00 01 00 02 de ad"

    computed = ChecksumProbe(src = 0x0001, dst = 0x0002,
                             checksum_mode = CHECKSUM_COMPUTED)
    bytes = to_bytes(computed)
    @test hex10(bytes[1:4]) == "00 01 00 02"
    # The mark of a correct internet checksum: the sum over the whole header,
    # checksum field included, folds to zero.
    @test ones_complement_checksum(bytes) == 0x0000
    # And it is the checksum of the header with the field zeroed.
    @test hex10(bytes[5:6]) ==
          hex10(reinterpret(UInt8, [hton(internet_checksum(computed))]))
end

@testset "checksum — computing one does not recurse" begin
    # `internet_checksum` serialises a copy whose mode is DECLARED, so the
    # derive that called it takes its other branch and stops.
    computed = ChecksumProbe(src = 0xffff, dst = 0xffff,
                             checksum_mode = CHECKSUM_COMPUTED)
    @test internet_checksum(computed) == internet_checksum(computed)
    @test with_field(computed, :checksum_mode, CHECKSUM_DECLARED).checksum_mode ==
          CHECKSUM_DECLARED
    @test_throws ErrorException with_field(computed, :nonesuch, 1)
end
