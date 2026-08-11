# ============================================================================
# Phase 21 — what a header knows about itself: where it is declared, how one is
# built, and what a field update does.
#
# The three facts are generic, so each is tested over every declared header and
# not over a chosen few. A gallery page shows them for ten headers; the facts
# themselves must hold for all of them.
# ============================================================================

using Test
using InetPacket.PacketModule

# The library's own wire formats, not the probes an earlier phase declared: a
# probe is registered too, and its clauses want values a generic fill cannot
# invent. This is the filter the round-trip corpus uses.
const LIBRARY_HEADERS = filter(H -> parentmodule(H) === PacketModule, list_headers())

@testset "phase 21 — a header's own facts" begin

@testset "every header records where it was declared" begin
    for H in LIBRARY_HEADERS
        site = find_declaration(H)
        @test site !== nothing
        @test endswith(site.file, ".jl")
        @test site.line > 0
        path = declaration_path(H)
        @test path !== nothing
        @test isfile(path)
        # The file that declares it says its name — the marker that puts a
        # declaration on a page addresses it by that name.
        @test occursin(string(nameof(H)), read(path, String))
    end
end

@testset "a hand-written header registers too" begin
    # `EthernetMacHeader` is a plain struct with no macro over it, so its
    # registration is the one written by hand.
    @test find_declaration(EthernetMacHeader) !== nothing
    @test basename(declaration_path(EthernetMacHeader)) == "Ethernet.jl"
    # And it has no keyword constructor, so it is built by stating all three
    # fields in order — which is what `IEEE 802.3` clause 3.2 gives it.
    @test !has_keyword_constructor(EthernetMacHeader)
    @test has_keyword_constructor(Ipv4Header)
    construction = describe_construction(EthernetMacHeader(MacAddress("0a:00:00:00:00:01"),
                                                           MacAddress("0a:00:00:00:00:02"),
                                                           EtherTypeOrLength(0x0800)))
    @test !construction.keyword
    # Three addresses do not fit on one line, so the call takes one argument per
    # line — the rule every long call here follows.
    @test construction.call ==
          "EthernetMacHeader(\n" *
          "    MacAddress(\"0a:00:00:00:00:01\"),\n" *
          "    MacAddress(\"0a:00:00:00:00:02\"),\n" *
          "    EtherTypeOrLength(0x0800))"
end

@testset "a derive that computes is left out, and one that does not is stated" begin
    # RFC 791 gives `ihl` a derive that counts the header, and gives
    # `header_checksum` one that hands back whatever the sender declared. The
    # first can be left out of a call and the second cannot, and the difference
    # is not in the declaration's shape — it is in what the writer puts back.
    header = example_header(Ipv4Header)
    construction = describe_construction(header)
    @test only(a for a in construction.arguments if a.name === :ihl).reason === :derived
    @test only(a for a in construction.arguments
                 if a.name === :header_checksum).reason === :differs
end

@testset "an example instance agrees with its own bytes" begin
    for H in LIBRARY_HEADERS
        header = example_header(H)
        @test header isa H
        # Encoding it again gives what it was decoded from, which is what makes
        # the shown instance an instance and not an approximation of one.
        bytes = encode_header(header)
        again = decode_header(H, bytes)
        again isa MarkedFields && (again = again.header)
        @test encode_header(again) == bytes
    end
end

@testset "the construction call rebuilds the header" begin
    for H in LIBRARY_HEADERS
        header = example_header(H)
        construction = describe_construction(header)
        @test construction.type === H
        @test startswith(construction.call, string(nameof(H)))
        # Every field is accounted for, once.
        @test Base.length(construction.arguments) == fieldcount(H)
        @test [a.name for a in construction.arguments] == collect(fieldnames(H))
        # A field the call leaves out is one the declaration already decides.
        for argument in list_omitted(construction)
            @test argument.reason in (:default, :derived, :fixed)
        end
        for argument in list_named(construction)
            @test argument.reason in (:required, :differs)
            # A keyword call names the field; a positional one states the value
            # in its place, and a plain struct has only the positional form.
            @test occursin(construction.keyword ? string(argument.name) : argument.literal,
                           construction.call)
        end
        # And the call runs, and builds a header that goes on the wire as the
        # one it was written from. Field equality is the wrong test: a derived
        # field is the writer's to fill in, so the bytes are the claim.
        rebuilt = Core.eval(PacketModule, Meta.parse(construction.call))
        @test rebuilt isa H
        @test encode_header(rebuilt) == encode_header(header)
    end
end

@testset "a header with no expressions names only what it decides" begin
    # RFC 768: two fields a caller must state, two the declaration defaults.
    construction = describe_construction(UdpHeader(source_port = 1000,
                                                   destination_port = 2000))
    @test construction.call == "UdpHeader(source_port = Port(1000), " *
                               "destination_port = Port(2000))"
    @test [a.name for a in list_omitted(construction)] == [:length, :checksum]
end

@testset "a derived field is never named" begin
    # RFC 791 §3.1: `ihl` derives from the header's own width, so a caller who
    # states it is either repeating the writer or contradicting it.
    header = Ipv4Header(total_length = 60, protocol = IP_PROTOCOL_UDP,
                        source = Ipv4Address("10.0.0.1"),
                        destination = Ipv4Address("10.0.0.2"))
    construction = describe_construction(header)
    ihl = only(a for a in construction.arguments if a.name === :ihl)
    @test ihl.reason === :derived
    @test !occursin("ihl", construction.call)
    @test occursin("Ipv4Address(\"10.0.0.1\")", construction.call)
end

@testset "one field update moves the bytes it should" begin
    for H in LIBRARY_HEADERS
        find_updatable_field(H) === nothing && continue
        update = describe_update(example_header(H))
        @test update.type === H
        @test update.before != update.after
        @test !isempty(update.changed)
        @test Base.length(update.before_bytes) == Base.length(update.after_bytes)
        # Exactly the reported bytes moved, and nothing else did.
        for i in eachindex(update.before_bytes)
            @test (update.before_bytes[i] != update.after_bytes[i]) == (i in update.changed)
        end
        # The value written is the value read back.
        rewritten = set_field(example_header(H), update.field,
                              Core.eval(PacketModule, Meta.parse(update.literal)))
        @test encode_header(rewritten) == update.after_bytes
    end
end

@testset "an update flips one byte of an IPv4 header" begin
    # The first field an update can show on: `version` is checked, `ihl` is
    # derived, so `dscp` is the first that is neither.
    update = describe_update(Ipv4Header(total_length = 60, protocol = IP_PROTOCOL_UDP,
                                        source = Ipv4Address("10.0.0.1"),
                                        destination = Ipv4Address("10.0.0.2")))
    @test update.field === :dscp
    @test update.changed == [2]
end

@testset "a value reads one way and rebuilds another" begin
    # `format_field` is for a reader and `literal_field` is for the compiler,
    # and the two are different questions about one value.
    @test format_field(Ipv4Address("10.0.0.1")) == "10.0.0.1"
    @test literal_field(Ipv4Address("10.0.0.1")) == "Ipv4Address(\"10.0.0.1\")"
    @test format_field(IpProtocol(17)) == "UDP (17)"
    @test literal_field(IpProtocol(17)) == "IpProtocol(17)"
    @test format_field(Checksum16(0x1234)) == "0x1234"
    @test literal_field(Checksum16(0x1234)) == "Checksum16(0x1234)"
    @test literal_field(MacAddress("0a:00:00:00:00:01")) ==
          "MacAddress(\"0a:00:00:00:00:01\")"
    # A number needs no method of its own: it prints as itself.
    @test literal_field(U4(5)) == "5"
    @test literal_field(true) == "true"
end

end # phase 21
