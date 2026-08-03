# ============================================================================
# Ethernet frame chunks + build helper.
#
# Faithful to INET's on-wire framing:
#   EthernetMacHeader  14 B — dst MAC (6) + src MAC (6) + ethertype/length (2)
#   payload            variable
#   padding            fill to MIN_ETHERNET_FRAME_BYTES = 64 counting header + FCS
#   EthernetFcs        4 B — declared mode; zero-filled (§3.1 of the plan)
#
# The 8-byte EthernetPhyHeader (preamble+SFD) is NOT added here — that's the
# PHY's job in Phase 2/3. Same split as INET (`EthernetCsmaPhy::encapsulate`).
#
# MAC addresses split into hi::UInt16 + lo::UInt32 = 48 bits, because @header
# doesn't (yet) natively express 48-bit fields. See plan §9 Q3.
# ============================================================================

# Constants matching INET's `linklayer/ethernet/common/Ethernet.h`.
const MIN_ETHERNET_FRAME_BYTES = 64
const MAX_ETHERNET_FRAME_BYTES = 1526
const INTERFRAME_GAP_BITS      = 96
const JAM_SIGNAL_BYTES         = 4
const ETHERNET_PHY_HEADER_LEN_BYTES = 8       # preamble(7) + SFD(1)
const ETHERNET_PHY_ESD_LEN_BYTES    = 1       # 5B code, modelled symbolically
const ETHERNET_TXRATE_10MB          = 10_000_000

# Common ethertypes we'll actually use — none of the target scenarios do
# per-ethertype demux, but we set the field faithfully.
const ETHERTYPE_IPV4 = UInt16(0x0800)
const ETHERTYPE_ARP  = UInt16(0x0806)

# ---------- headers ----------------------------------------------------------

@header EthernetMacHeader begin
    dst_mac_hi   :: UInt16
    dst_mac_lo   :: UInt32
    src_mac_hi   :: UInt16
    src_mac_lo   :: UInt32
    ethertype    :: UInt16
end

@header EthernetFcs begin
    fcs :: UInt32
end

# ---------- MAC address helpers ----------------------------------------------
#
# We pack the 48-bit MAC into a UInt64 for convenience (top 16 bits zero).
# `mac_hi` / `mac_lo` split it for the @header split-field form; `mac_pack`
# is the inverse. Reads are exact — no signed-int surprises.

mac_pack(hi::UInt16, lo::UInt32) = (UInt64(hi) << 32) | UInt64(lo)
mac_hi(m::UInt64)::UInt16 = UInt16((m >> 32) & 0xFFFF)
mac_lo(m::UInt64)::UInt32 = UInt32(m & 0xFFFFFFFF)

# ---------- build_ethernet_frame --------------------------------------------

"""
    build_ethernet_frame(src::UInt64, dst::UInt64,
                        ethertype::UInt16, payload::Chunk) -> Packet

Wrap `payload` into a Packet whose content is
`EthernetMacHeader + payload + optional padding + EthernetFcs`, matching
INET's `EthernetCsmaMac::addPaddingAndSetFcs`. Padding brings the total
frame length (header + payload + padding + FCS) up to `MIN_ETHERNET_FRAME_BYTES`
if it's below.

FCS is zero-filled (declared mode — `fcsMode = "declared"`, INET's default).
"""
function build_ethernet_frame(src::UInt64, dst::UInt64,
                              ethertype::UInt16, payload::Chunk)
    header = EthernetMacHeader(mac_hi(dst), mac_lo(dst),
                               mac_hi(src), mac_lo(src),
                               ethertype)
    pk = Packet(payload)
    pushfirst!(pk, header)
    # Compute what the frame would be with just header + payload + FCS.
    tentative_bytes = data_length(pk).bits >> 3 + 4      # + FCS
    if tentative_bytes < MIN_ETHERNET_FRAME_BYTES
        pad_bytes = MIN_ETHERNET_FRAME_BYTES - tentative_bytes
        push!(pk, Filler(Bytes(pad_bytes); fill = 0x00))
    end
    push!(pk, EthernetFcs(0x00000000))
    return pk
end
