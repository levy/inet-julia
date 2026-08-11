# ============================================================================
# Phase 11 — `@header`, and the two things a type cannot hold.
#
# The macro emits no codec. It emits the same struct a hand-written declaration
# would, plus the defaults and the expressions over sibling fields. So a header
# from the macro and a header from a plain `struct` are the same kind of thing,
# and everything `HeaderCodec.jl` does, it does to both.
# ============================================================================
using Test
using InetPacket.PacketModule

hex11(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- defaults ----------------------------------------------------------------

@testset "a default is what the standard fixes" begin
    # RFC 791 fixes the version, the header length and the initial TTL; a
    # datagram decides the rest. So a call site names four fields.
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    @test ip.version == 4
    @test ip.ihl == 5
    @test ip.time_to_live == 64
    @test !ip.dont_fragment
    @test ip.source == Ipv4Address("10.0.0.1")

    # A field with no default stays required.
    @test_throws UndefKeywordError Ipv4Header(protocol = IP_PROTOCOL_UDP,
                                              source = "10.0.0.1",
                                              destination = "10.0.0.2")
    # The positional constructor is still there, and still takes every field.
    @test Base.length(fieldnames(Ipv4Header)) == 18
end

# --- derive ------------------------------------------------------------------

@testset "derive — the writer computes, the reader keeps what arrived" begin
    @test list_derived(Ipv4Header) == (:ihl, :header_checksum)

    # RFC 791 defines `ihl` over the header alone, so the codec computes it and
    # the struct's value never reaches the wire.
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    wrong = set_field(ip, :ihl, 9)
    @test encode_header(wrong)[1] & 0x0f == 5      # 20 bytes is five words
    @test encode_header(wrong) == encode_header(ip)

    # The reader keeps the wire value, so a foreign sender's disagreement is
    # visible instead of silently corrected.
    # `ihl` says seven words, so the header is 28 bytes and the reader needs
    # them: a datagram that claims more than it carries is truncated, not a
    # round-trip subject.
    arrived = vcat(copy(encode_header(ip)), zeros(UInt8, 8))
    arrived[1] = 0x47                              # version 4, ihl 7
    @test decode_header(Ipv4Header, arrived).ihl == 7
end

@testset "derive — a clause reads the other fields by name" begin
    # `total_length` counts the payload, which the header cannot see, so RFC 791
    # leaves it to the IP module and this declaration gives it no derive.
    @test !(:total_length in list_derived(Ipv4Header))
    @test !(:payload_length in list_derived(Ipv6Header))
end

# --- check -------------------------------------------------------------------

@testset "check — a bad version marks, and does not throw" begin
    @test list_checked(Ipv4Header) == (:version, :header)
    @test list_checked(Ipv6Header) == (:version,)

    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    good = encode_header(ip)
    @test decode_header(Ipv4Header, good) == ip
    @test quality(decode_header(Ipv4Header, good)) == Q_COMPLETE

    bad = copy(good)
    bad[1] = 0x55                                  # version 5, which no IPv4 has
    marked = decode_header(Ipv4Header, bad)
    @test marked isa MarkedFields{Ipv4Header}
    @test quality(marked) == Q_INCORRECT
    # The header is still there: a malformed packet is data, not an exception.
    @test marked.header.version == 5
    @test marked.header.source == Ipv4Address("10.0.0.1")
end

@testset "check — a header the MODEL built wrong throws on write" begin
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    @test_throws ErrorException encode_header(set_field(ip, :version, 5))
    # The `@check` line spans fields, and refuses the same way.
    @test_throws ErrorException encode_header(set_field(ip, :ihl, 4))
end

@testset "check — peek gates on what the deserialiser said" begin
    ip = Ipv6Header(payload_length = 8, next_header = IP_PROTOCOL_UDP,
                    source = "2001:db8::1", destination = "::1")
    bad = copy(encode_header(ip))
    bad[1] = 0x50
    source = Raw(bad)
    @test quality(source) == Q_COMPLETE            # the bytes themselves are fine

    @test_throws ErrorException peek(source, Ipv6Header)
    accepted = peek(source, Ipv6Header; incorrect = true)
    @test accepted isa Ipv6Header                  # the envelope is stripped
    @test accepted.version == 5
    @test peek(Raw(encode_header(ip)), Ipv6Header) == ip
end

# --- a model-only field ------------------------------------------------------

@testset "a Model field is in the struct and never on the wire" begin
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    @test ip.checksum_mode == CHECKSUM_DECLARED    # the box is invisible
    @test ip.checksum_mode isa ChecksumMode
    @test getfield(ip, :checksum_mode) isa Model{ChecksumMode}

    @test minimum_chunk_length(Ipv4Header) == Bytes(20)
    names = [f.name for f in describe_layout(Ipv4Header).fields]
    @test !(:checksum_mode in names)               # the layout describes the wire
    @test Base.length(names) == 15
end

@testset "a checksum is a derive that reads the mode" begin
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2",
                    header_checksum = 0xdead)
    # Declared is the default and the mode a capture round-trips under: the
    # stored value goes out untouched, however wrong it is.
    @test hex11(encode_header(ip)[11:12]) == "de ad"

    computed = set_field(ip, :checksum_mode, CHECKSUM_COMPUTED)
    bytes = encode_header(computed)
    @test hex11(bytes[11:12]) == "66 bb"
    # The mark of a correct internet checksum: the sum over the whole header,
    # checksum field included, folds to zero.
    @test compute_ones_complement(bytes) == 0x0000
    # And computing it does not recurse: the copy it serialises says declared.
    @test compute_internet_checksum(computed, :header_checksum) ==
          compute_internet_checksum(computed, :header_checksum)
end

# --- the macro and the plain struct are the same thing -----------------------

@testset "a macro header and a hand-written one are the same kind" begin
    # `EthernetMacHeader` is a plain struct, `Ipv4Header` comes from the macro.
    for H in (EthernetMacHeader, Ipv4Header, UdpHeader, Ipv6Header, TcpHeader)
        @test H <: Fields
        # IPv4 and TCP carry option lists, so their length is a property of the
        # value; the others are the same width every time.
        @test describe_layout(H).length == minimum_chunk_length(H)
    end
    @test is_fixed_length(EthernetMacHeader)
    @test is_fixed_length(UdpHeader)
    @test !is_fixed_length(Ipv4Header)
    # A plain struct simply has no clause, and needs no method for one.
    @test list_derived(EthernetMacHeader) == ()
    @test list_checked(EthernetMacHeader) == ()
end

# --- what the macro refuses --------------------------------------------------

@testset "the macro refuses a declaration it cannot mean" begin
    # A clause with no field above it belongs to nothing.
    @test_throws LoadError @eval @header BadOrphanClause begin
        check(true)
        value :: U8
    end
    # Two of the same clause on one field is a contradiction, not an addition.
    @test_throws LoadError @eval @header BadTwoChecks begin
        value :: U8
        check(value == 1)
        check(value == 2)
    end
    # A clause the macro does not know is a typo.
    @test_throws LoadError @eval @header BadClauseName begin
        value :: U8
        whenever(true)
    end
end
