# ============================================================================
# Phase 5 conformance — packet tags + region tags.
#
# Ports: testTagSet, testRegionTagSet, testPacketTags, testRegionTags,
# testChunkRegionTags, testPacketRegionTags, testIdentityTag.
# Verify: the unification decision is settled HERE (§4.3), by whether both
# region-tag tests pass against ONE mechanism. Recorded in the plan.
# ============================================================================
using Test
using Inet.PacketModule

# Tag types for the fixtures. `Req`/`Ind` reproduces INET's down/up convention.
struct L3AddressReq; addr::UInt32; end
struct SocketInd;    fd::Int;      end
struct GenericAppMsgReq
    id::Int
    length::Int
end
struct ResidenceTimeTag
    ns::Int
end

# --- testTagSet --------------------------------------------------------------
@testset "TagSet — at-most-one-per-type" begin
    ts = TagSet()
    @test isempty(ts)
    @test Base.length(ts) == 0

    ts[L3AddressReq] = L3AddressReq(0x0a000001)
    @test !isempty(ts)
    @test haskey(ts, L3AddressReq)
    @test ts[L3AddressReq].addr == 0x0a000001
    @test tryget(ts, SocketInd) === nothing

    # Overwrite — still one entry per type.
    ts[L3AddressReq] = L3AddressReq(0x0a000002)
    @test Base.length(ts) == 1
    @test ts[L3AddressReq].addr == 0x0a000002

    ts[SocketInd] = SocketInd(3)
    @test Base.length(ts) == 2
    delete!(ts, SocketInd)
    @test !haskey(ts, SocketInd)
end

# --- testPacketTags ----------------------------------------------------------
@testset "packet tags via set_tag!/get_tag" begin
    pk = Packet(Filler(Bytes(64)))
    @test !has_tag(pk, L3AddressReq)

    set_tag!(pk, L3AddressReq(0x0a010203))
    @test has_tag(pk, L3AddressReq)
    @test get_tag(pk, L3AddressReq).addr == 0x0a010203
    @test try_tag(pk, SocketInd) === nothing

    del_tag!(pk, L3AddressReq)
    @test !has_tag(pk, L3AddressReq)
end

# --- testRegionTagSet --------------------------------------------------------
@testset "RegionTagSet — non-overlap per type, intersection query" begin
    rs = RegionTagSet()
    add_region_tag!(rs, GenericAppMsgReq, 0:1023, GenericAppMsgReq(1, 1024))
    add_region_tag!(rs, GenericAppMsgReq, 1024:2047, GenericAppMsgReq(2, 1024))

    # Overlap for the same TYPE → error.
    @test_throws ErrorException add_region_tag!(rs, GenericAppMsgReq,
                                                500:1500, GenericAppMsgReq(3, 1001))
    # A different type over the same range is fine — they don't interfere.
    add_region_tag!(rs, ResidenceTimeTag, 0:2047, ResidenceTimeTag(42))

    hits = region_tags(rs, GenericAppMsgReq, 800:1200)
    @test Base.length(hits) == 2
    @test hits[1][2].id == 1 && hits[1][1] == 800:1023
    @test hits[2][2].id == 2 && hits[2][1] == 1024:1200
end

# --- testPacketRegionTags ---------------------------------------------------
@testset "packet region tags — data-window coordinates" begin
    pk = Packet(Filler(Bytes(200)))
    add_region_tag!(pk, ResidenceTimeTag, 0:1599, ResidenceTimeTag(100))
    hits = region_tags(pk, ResidenceTimeTag)
    @test Base.length(hits) == 1
    @test hits[1][2].ns == 100
    @test hits[1][1] == 0:1599                # data-window bit range
end

# --- push! / pop! shift region tag ranges eagerly ---------------------------
@testset "region tags follow push/pop of headers" begin
    pk = Packet(Filler(Bytes(64)))
    add_region_tag!(pk, ResidenceTimeTag, 0:511, ResidenceTimeTag(5))
    # Prepend a 20-byte header: existing tag range shifts by 160 bits.
    pushfirst!(pk, Raw(collect(UInt8, 1:20)))
    # In data-window coords the tag is now at 160:671 (was 0:511, header is 0:159)
    hits = region_tags(pk, ResidenceTimeTag)
    @test Base.length(hits) == 1
    @test hits[1][1] == 160:671
end

# --- testChunkRegionTags — the SAME mechanism, used standalone --------------
@testset "region tags on a bare chunk (no packet)" begin
    rs = RegionTagSet()
    add_region_tag!(rs, GenericAppMsgReq, 100:199, GenericAppMsgReq(7, 100))
    hits = region_tags(rs, GenericAppMsgReq, 0:1000)
    @test Base.length(hits) == 1 && hits[1][2].id == 7
    @test hits[1][1] == 100:199
    # ONE mechanism serves both packet and standalone use — that's the
    # unification the plan §4.3 proposed. Decision recorded in the plan.
end

# --- testIdentityTag — tag values are stored by identity, not copied --------
@testset "tag values are stored by identity" begin
    pk = Packet(Filler(Bytes(32)))
    val = L3AddressReq(0x99)
    set_tag!(pk, val)
    @test get_tag(pk, L3AddressReq) === val   # === identity, not equality
end

# --- dup copies tag sets — mutating d must not touch pk --------------------
@testset "dup copies tag sets" begin
    pk = Packet(Filler(Bytes(64)))
    set_tag!(pk, L3AddressReq(0x1))
    d = dup(pk)
    set_tag!(d, L3AddressReq(0x2))
    @test get_tag(pk, L3AddressReq).addr == 0x1
    @test get_tag(d,  L3AddressReq).addr == 0x2

    add_region_tag!(pk, ResidenceTimeTag, 0:63, ResidenceTimeTag(1))
    d2 = dup(pk)
    add_region_tag!(d2, ResidenceTimeTag, 64:127, ResidenceTimeTag(2))
    @test Base.length(region_tags(pk, ResidenceTimeTag)) == 1
    @test Base.length(region_tags(d2, ResidenceTimeTag)) == 2
end

# --- trim! drops tags outside the surviving window and shifts survivors -----
@testset "trim! clips and shifts region tags" begin
    pk = Packet(Raw(collect(UInt8, 1:40)))
    popfirst!(pk, Bytes(10))
    pop!(pk, Bytes(5))
    add_region_tag!(pk, ResidenceTimeTag, 0:79, ResidenceTimeTag(10))   # data-window coords
    # Add one entirely outside the data window (in the retained prefix region).
    # We shift back to content coords: `front` is 80 bits, so the pk data window
    # starts at content-bit 80. Add a tag directly into the underlying set at
    # content bits 40..79 (in the retained prefix).
    add_region_tag!(pk.region_tags, ResidenceTimeTag, 40:79, ResidenceTimeTag(99))

    trim!(pk)
    hits = region_tags(pk, ResidenceTimeTag)
    @test Base.length(hits) == 1               # the outside-tag dropped
    @test hits[1][2].ns == 10                  # the surviving one
    @test hits[1][1] == 0:79                   # ranges are back to origin
end
