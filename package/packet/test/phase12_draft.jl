# ============================================================================
# Phase 12 — `Draft`, where a hole is allowed.
#
# No field of a header is `Union{T, Nothing}`, so a header is always true about
# a packet. Genuine incremental construction lives in a different type, and
# `build_header` is the one door between the two.
# ============================================================================
using Test
using InetPacket.PacketModule

@testset "a draft starts where the standard does" begin
    draft = start_draft(Ipv4Header)
    @test header_type(draft) === Ipv4Header

    # RFC 791 fixes these, so a builder does not have to decide them.
    @test is_set(draft, :version)
    @test is_set(draft, :time_to_live)
    @test draft.version == 4
    @test draft.time_to_live == 64

    # These a datagram decides, so they start empty.
    @test !is_set(draft, :total_length)
    @test !is_set(draft, :protocol)
    @test list_unset(draft) == [:total_length, :protocol, :source, :destination]
end

@testset "a draft refuses to be read where it is empty" begin
    draft = start_draft(Ipv4Header)
    @test_throws ErrorException draft.protocol
    @test_throws ErrorException start_draft(Ipv4Header).source
    # A field no header has is a different error, and it names what there is.
    @test_throws ErrorException draft.nonesuch
    @test_throws ErrorException set_field!(draft, :nonesuch, 1)
end

@testset "a draft fills field by field, and converts as it goes" begin
    draft = start_draft(Ipv4Header)
    draft.source = "10.0.0.1"                      # a string reaches Ipv4Address
    set_field!(draft, :destination, "10.0.0.2")
    @test draft.source == Ipv4Address("10.0.0.1")
    @test is_set(draft, :source)
    @test list_unset(draft) == [:total_length, :protocol]

    # A hole may be put back, because a draft is where a hole is allowed.
    unset_field!(draft, :source)
    @test !is_set(draft, :source)
    draft.source = "10.0.0.1"

    draft.protocol = IP_PROTOCOL_UDP
    draft.total_length = 48
    ip = build_header(draft)
    @test ip isa Ipv4Header
    @test ip.source == Ipv4Address("10.0.0.1")
    @test ip.protocol == IP_PROTOCOL_UDP
    @test ip.version == 4
end

@testset "build_header refuses a half-built header, and names every hole" begin
    draft = start_draft(Ipv4Header)
    draft.source = "10.0.0.1"
    draft.destination = "10.0.0.2"
    message = try
        build_header(draft)
        ""
    catch exception
        sprint(showerror, exception)
    end
    @test occursin("still unset", message)
    @test occursin("total_length", message)
    @test occursin("protocol", message)            # both, not just the first
end

@testset "a draft of an existing header starts complete" begin
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    draft = start_draft(ip)
    @test isempty(list_unset(draft))
    @test build_header(draft) == ip

    draft.time_to_live = 63
    forwarded = build_header(draft)
    @test forwarded.time_to_live == 63
    @test ip.time_to_live == 64                    # the original is untouched
end

@testset "a header written as a plain struct drafts too" begin
    # `EthernetMacHeader` has no macro and therefore no default, so every field
    # of its draft starts unset.
    draft = start_draft(EthernetMacHeader)
    @test list_unset(draft) == [:destination, :source, :type_or_length]
    draft.destination = MAC_BROADCAST
    draft.source = "0a:00:00:00:00:01"
    draft.type_or_length = ETHERTYPE_ARP
    @test build_header(draft) ==
          EthernetMacHeader(MAC_BROADCAST, "0a:00:00:00:00:01", ETHERTYPE_ARP)
end

@testset "a draft shows its holes" begin
    text = string(start_draft(EthernetMacHeader))
    @test occursin("Draft{EthernetMacHeader}", text)
    @test occursin("destination=?", text)
end
